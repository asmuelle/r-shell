# Release Skill

Create a new release for R-Shell.

## Workflow

1. **Ask user for version bump type** (patch, minor, or major)
   - Patch: bug fixes (1.2.0 → 1.2.1)
   - Minor: new features, backwards compatible (1.2.0 → 1.3.0)
   - Major: breaking changes (1.2.0 → 2.0.0)

2. **Run version bump script**
   ```bash
   echo "y" | pnpm run version:{patch|minor|major}
   ```
   This updates:
   - package.json
   - src-tauri/Cargo.toml
   - src-tauri/tauri.conf.json
   - src-tauri/Cargo.lock
   - CHANGELOG.md (with placeholder entries)
   - Creates a git commit

3. **Update CHANGELOG.md** with actual changes:
   - Get commits since last tag: `git log v{prev_version}..HEAD --oneline --no-merges`
   - Get detailed commit messages: `git log v{prev_version}..HEAD --pretty=format:"%h %s%n%b" --no-merges`
   - Follow the existing changelog format with emoji prefixes
   - Categories: Added, Changed, Fixed, Removed

4. **Amend the commit** with updated CHANGELOG:
   ```bash
   git add CHANGELOG.md && git commit --amend --no-edit
   ```

5. **Create and push git tag**:
   ```bash
   git tag v{new_version}
   git push origin v{new_version}
   ```

6. **Create draft GitHub release**:
   ```bash
   gh release create v{new_version} --draft --title "v{new_version}" --notes "{changelog_content}"
   ```

## Notes

- Always verify the previous commit was made by the assistant before amending
- Check that the commit hasn't been pushed before amending
- The release is created as a draft — user can review and publish in GitHub UI
- Follow Keep a Changelog format with emoji prefixes matching existing entries
