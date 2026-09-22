# Publishing the 1.0 candidate

Publication is the final step after every gate in `RELEASE_PLAN.md` passes on
one immutable commit. The current tracker does not yet claim that these gates
have passed. Publication follows review of the completed candidate.

## Candidate preparation

1. Set `Project.toml` to `1.0.0`, resolve the tracked docs manifest, and commit
   the final release notes, compatibility contract, comparison results and fixes.
2. Run **Release validation** at that commit. Require all native platform shards,
   browser fixtures, registered examples, installed consumers and exported-asset
   pixel checks. Require strict documentation and the pinned comparison checks
   on the same source. Retain raw artifacts and record their run URLs.
3. Verify a clean checkout, the commit ID, its Git tree ID, package version,
   public API inventory, and all result-file revisions. A source change requires
   rechecking its affected gates before publication.

## Registration and release

Use the existing Git credentials for the version tag. No repository Actions
secrets were configured when this procedure was prepared; it does not depend on
TagBot or an unconfigured SSH deploy key.

After the candidate and publication are approved:

1. Submit `@JuliaRegistrator register` on the **verified candidate commit**, and
   paste `release/1.0/release-notes.md` into that same comment under a
   `Release notes:` line, so Registrator copies it into the registry pull
   request between its `<!-- BEGIN RELEASE NOTES -->` and
   `<!-- END RELEASE NOTES -->` markers:

   ```
   @JuliaRegistrator register

   Release notes:

   ## Breaking changes
   ...
   ```

   This is required, not optional. Registering 1.0.0 over 0.1.8 changes the major
   version, so `RegistryTools` adds the `BREAKING` label
   ([`src/register.jl`](https://github.com/JuliaRegistries/RegistryTools.jl/blob/master/src/register.jl),
   `version.major != previous.major` -> `:breaking`). General runs AutoMerge with
   `check_breaking_explanation = true`, whose guideline rejects a `BREAKING`
   registration unless the release notes in the pull-request body match
   `breaking|changelog`
   ([`AutoMerge/src/guidelines.jl`](https://github.com/JuliaRegistries/RegistryCI.jl/blob/master/AutoMerge/src/guidelines.jl),
   `meets_breaking_explanation_check`). The prepared notes open with a
   `## Breaking changes` section for exactly this reason; keep that wording.

   Check the generated General registry PR against that commit's package UUID,
   version, tree hash and compatibility entries. Wait for registry checks and
   merge; do not substitute a later `main` commit.
2. Create the annotated `v1.0.0` Git tag at that same commit and push that exact
   tag through the current Git credentials. The tag push triggers versioned
   documentation. A tag/package-version mismatch fails before the docs build.
3. Require the tagged documentation build and inspect both `/v1.0.0/` and
   `/stable/`. Development pushes deploy to `/dev/`.
4. Publish the GitHub release from the existing tag with the approved notes and
   evidence artifacts. Finally install `Diff3D@1.0.0` from General in a fresh
   environment, rerun the consumer acceptance checks, and verify the registry's
   tree hash and the release's downloadable source.

The exact commit, tree, registration comment and tag/release commands belong in
the final candidate record after verification; they are not filled from a
moving branch. Registry review or service delays remain external pending work.

References: [Registrator](https://github.com/JuliaRegistries/Registrator.jl),
[versioned Documenter hosting](https://documenter.juliadocs.org/stable/man/hosting/),
and [TagBot authentication and workflow triggers](https://github.com/JuliaRegistries/TagBot#ssh-deploy-keys).
