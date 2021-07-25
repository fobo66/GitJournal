import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:dart_git/dart_git.dart';
import 'package:dart_git/exceptions.dart';
import 'package:function_types/function_types.dart';
import 'package:path/path.dart' as p;

import 'package:gitjournal/utils/logger.dart';

class GitTransferProgress {
  int totalObjects = 0;
  int indexedObjects = 0;
  int receivedObjects = 0;
  int localObjects = 0;
  int totalDeltas = 0;
  int indexedDeltas = 0;
  int receivedBytes = 0;

  static Future<GitTransferProgress?> load(String statusFile) async {
    if (!File(statusFile).existsSync()) {
      return null;
    }
    var str = await File(statusFile).readAsString();
    var parts = str.split(' ');
    print('GitTransferProgress: #$str#');

    var tp = GitTransferProgress();
    tp.totalObjects = int.parse(parts[0]);
    tp.indexedObjects = int.parse(parts[1]);
    tp.receivedObjects = int.parse(parts[2]);
    tp.localObjects = int.parse(parts[3]);
    tp.totalDeltas = int.parse(parts[4]);
    tp.indexedDeltas = int.parse(parts[5]);
    tp.receivedBytes = int.parse(parts[6]);
    return tp;
  }
}

typedef GitFetchFunction = Future<Result<void>> Function(
  String repoPath,
  String remoteName,
  String sshPublicKey,
  String sshPrivateKey,
  String sshPassword,
  String statusFile,
);

typedef GitDefaultBranchFunction = Future<Result<String>> Function(
  String repoPath,
  String remoteName,
  String sshPublicKey,
  String sshPrivateKey,
  String sshPassword,
);

typedef GitMergeFn = Future<Result<void>> Function(
  String repoPath,
  String remoteName,
  String remoteBranchName,
  String authorName,
  String authorEmail,
);

Future<Result<void>> cloneRemotePluggable({
  required String repoPath,
  required String cloneUrl,
  required String remoteName,
  required String sshPublicKey,
  required String sshPrivateKey,
  required String sshPassword,
  required String authorName,
  required String authorEmail,
  required Func1<GitTransferProgress, void> progressUpdate,
  required GitFetchFunction gitFetchFn,
  required GitDefaultBranchFunction defaultBranchFn,
  required GitMergeFn gitMergeFn,
}) async {
  var repo = await GitRepository.load(repoPath).getOrThrow();
  var remote = await repo.addOrUpdateRemote(remoteName, cloneUrl).getOrThrow();

  var statusFile = p.join(Directory.systemTemp.path, 'gj');
  var duration = const Duration(milliseconds: 50);
  var timer = Timer.periodic(duration, (_) async {
    var progress = await GitTransferProgress.load(statusFile);
    if (progress != null) {
      progressUpdate(progress);
    }
  });

  var fetchR = await gitFetchFn(repoPath, remoteName, sshPublicKey,
      sshPrivateKey, sshPassword, statusFile);
  timer.cancel();
  if (fetchR.isFailure) {
    // FIXME: Give a better error?
    return fail(fetchR);
  }

  var branchNameR = await defaultBranchFn(
      repoPath, remoteName, sshPublicKey, sshPrivateKey, sshPassword);
  if (branchNameR.isFailure) {
    return fail(branchNameR);
  }
  var remoteBranchName = branchNameR.getOrThrow();

  Log.i("Using remote branch: $remoteBranchName");

  var branches = await repo.branches().getOrThrow();
  if (branches.isEmpty) {
    Log.i("Completing - no local branch");
    var remoteBranchR = await repo.remoteBranch(remoteName, remoteBranchName);
    if (remoteBranchR.isFailure) {
      if (remoteBranchR.error is! GitNotFound) {
        return fail(remoteBranchR);
      }

      // remoteBranch doesn't exist - do nothing? Are you sure?
    } else {
      // remote branch exists
      var remoteBranch = remoteBranchR.getOrThrow();
      await repo.createBranch(remoteBranchName, hash: remoteBranch.hash);
      await repo.checkoutBranch(remoteBranchName);
    }

    // FIXME: This will fail if the currentBranch doesn't exist!!
    await repo.setUpstreamTo(remote, remoteBranchName).getOrThrow();
  } else {
    Log.i("Local branches $branches");
    var branch = branches[0];

    if (branch == remoteBranchName) {
      Log.i("Completing - localBranch: $branch");

      var currentBranch = await repo.currentBranch().getOrThrow();
      if (currentBranch != branch) {
        // Shit happens sometimes
        // There is only one local branch, and that branch is not the current
        // branch, wtf?
        await repo.checkoutBranch(branch);
      }

      await repo.setUpstreamTo(remote, remoteBranchName).getOrThrow();
      var remoteBranchR = await repo.remoteBranch(remoteName, remoteBranchName);
      if (remoteBranchR.isSuccess) {
        Log.i("Merging '$remoteName/$remoteBranchName'");
        var r = await gitMergeFn(
            repoPath, remoteName, remoteBranchName, authorName, authorEmail);
        if (r.isFailure) {
          return fail(r);
        }
      }
    } else {
      Log.i("Completing - localBranch diff remote: $branch $remoteBranchName");
      await repo.createBranch(remoteBranchName).getOrThrow();
      await repo.checkoutBranch(remoteBranchName).getOrThrow();

      await repo.deleteBranch(branch).getOrThrow();
      await repo.setUpstreamTo(remote, remoteBranchName).getOrThrow();

      Log.i("Merging '$remoteName/$remoteBranchName'");
      var r = await gitMergeFn(
          repoPath, remoteName, remoteBranchName, authorName, authorEmail);
      if (r.isFailure) {
        return fail(r);
      }
    }
  }

  // Just to be on the safer side, incase dart-git fucks up something
  // dart-git does fuck something up. This is required!
  // Causes problems -
  // - Pack files are read into memory, this causes OOM issues
  //   https://sentry.io/organizations/gitjournal/issues/2254310735/?project=5168082&query=is%3Aunresolved
  //
  var r = await repo.checkout(".");
  if (r.isFailure) {
    return fail(r);
  }

  return Result(null);
}

String folderNameFromCloneUrl(String cloneUrl) {
  var name = p.basename(cloneUrl);
  if (name.endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }
  return name;
}

// Test Cases -
// * New Repo, No Local Changes
// * New Repo, Existing Changes
// * Existing Repo (master default), No Local Changes
// * Existing Repo (master default), Local changes in 'master' branch
// * Existing Repo (main default), Local changes in 'master' branch
