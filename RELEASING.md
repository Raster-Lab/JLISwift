# Release Strategy & Workflow

JLISwift uses **semantic versioning** and **automated releases** via GitHub Actions.

## Version Format

```
MAJOR.MINOR.PATCH[-PRERELEASE]
```

| Component | When to Increment |
|-----------|-------------------|
| **MAJOR** | Breaking API changes |
| **MINOR** | New features, backward compatible |
| **PATCH** | Bug fixes, backward compatible |
| **PRERELEASE** | Alpha, beta, or release candidate (e.g., `1.0.0-beta.1`) |

## Automated Workflows

### 1. Continuous Integration (CI)

**Trigger:** Every push to `main`/`develop` and all pull requests

**What it does:**
- ✅ Builds on macOS with latest Xcode
- ✅ Builds on Linux with Swift 6.0
- ✅ Runs all 87+ unit tests
- ✅ Generates code coverage reports
- ✅ Validates builds for iOS, tvOS, watchOS, visionOS

### 2. Release Workflow

**Trigger:** Push of a version tag (`v*.*.*`)

**What it does:**
1. Validates the release (build + test)
2. Generates changelog from commit messages
3. Creates a GitHub Release with:
   - Categorized release notes (features, fixes, etc.)
   - Installation instructions
4. Notifies Swift Package Index to update

### 3. Version Bump Workflow

**Trigger:** Manual (workflow_dispatch)

**What it does:**
1. Calculates the new version based on bump type
2. Updates version in `JLISwift.swift`
3. Commits and tags the release
4. Triggers the Release workflow automatically

## How to Release

### Option A: Automated (Recommended)

1. Go to **Actions** → **Version Bump**
2. Click **Run workflow**
3. Select bump type:
   - `patch` for bug fixes (1.0.0 → 1.0.1)
   - `minor` for new features (1.0.0 → 1.1.0)
   - `major` for breaking changes (1.0.0 → 2.0.0)
4. Optionally add pre-release identifier (`alpha`, `beta`, `rc`)
5. Click **Run workflow**

The workflow will:
- Bump the version
- Create a git tag
- Trigger the release workflow
- Create a GitHub Release with changelog

### Option B: Manual

```bash
# 1. Update version in source
# Edit Sources/JLISwift/JLISwift.swift:
#   public static let version = "X.Y.Z"

# 2. Commit the change
git add -A
git commit -m "chore: bump version to X.Y.Z"

# 3. Create and push tag
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin main --follow-tags
```

## Commit Message Convention

Use [Conventional Commits](https://www.conventionalcommits.org/) for automatic changelog generation:

| Prefix | Description | Example |
|--------|-------------|---------|
| `feat:` | New feature | `feat: add progressive JPEG encoding` |
| `fix:` | Bug fix | `fix: correct DCT coefficient rounding` |
| `perf:` | Performance | `perf: optimize Huffman decoding` |
| `docs:` | Documentation | `docs: add API usage examples` |
| `test:` | Tests | `test: add encoder edge case tests` |
| `chore:` | Maintenance | `chore: bump version to 1.2.0` |
| `refactor:` | Code refactor | `refactor: simplify color conversion` |

### Examples

```bash
# Feature
git commit -m "feat: add 16-bit image support"

# Bug fix
git commit -m "fix: handle odd-dimension images correctly"

# Breaking change (use ! or BREAKING CHANGE footer)
git commit -m "feat!: rename JLIEncoder.encode() to encodeJPEG()"
```

## Release Checklist

Before releasing:

- [ ] All tests pass (`swift test`)
- [ ] Build succeeds on all platforms
- [ ] Version number updated in `JLISwift.swift`
- [ ] CHANGELOG or release notes prepared
- [ ] README updated if API changed
- [ ] Breaking changes documented

## Pre-release Versions

For testing before a stable release:

```bash
# Alpha (early testing)
# Run Version Bump with prerelease = "alpha"
# Creates: v1.0.0-alpha

# Beta (feature complete, testing)
# Run Version Bump with prerelease = "beta"
# Creates: v1.0.0-beta

# Release Candidate (final testing)
# Run Version Bump with prerelease = "rc.1"
# Creates: v1.0.0-rc.1
```

## Swift Package Index

After release, the package is automatically submitted to [Swift Package Index](https://swiftpackageindex.com/). To register your package initially:

1. Go to https://swiftpackageindex.com/add-a-package
2. Enter: `https://github.com/Raster-Lab/JLISwift.git`
3. Submit for indexing

## Troubleshooting

### Release workflow failed

1. Check the **Actions** tab for error details
2. Common issues:
   - Tests failing: Fix tests and re-tag
   - Permission denied: Check repository permissions

### Need to re-release the same version

```bash
# Delete the tag locally and remotely
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z

# Re-create and push
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

### Cancel a release

1. Go to **Releases** on GitHub
2. Find the release and click **Delete**
3. Optionally delete the tag as shown above
