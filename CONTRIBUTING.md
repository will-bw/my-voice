# Contributing to my-voice

This is an independent modified version of [VoiceInk](https://github.com/Beingpax/VoiceInk), maintained by [will-bw](https://github.com/will-bw). Report issues for this version in [will-bw/my-voice](https://github.com/will-bw/my-voice/issues).

The guidance below is retained from upstream as a development reference; references to the VoiceInk community and its contribution policy describe the upstream project. This fork currently prioritizes issue reports and does not promise pull request review. Contributions to this fork must be compatible with its GNU GPL v3 license.

# Contributing to VoiceInk

First off, thank you for considering contributing to VoiceInk! It's people like you that make VoiceInk such a great tool.

## ⚠️ Pull Requests Not Accepted

**As of now, this project is not accepting pull requests.** VoiceInk is open source, and you're welcome to fork and modify it for your own use.

**You can still contribute by:**
- 🐛 **Reporting bugs** - Open an issue with detailed information
- 💡 **Suggesting features** - Share your ideas via issues or discussions
- 🍴 **Forking the project** - Feel free to create your own version
- 📖 **Improving documentation** - Suggest clarifications or corrections via issues

Thank you for understanding!

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## How Can I Contribute?

### Reporting Bugs

- Before submitting a bug report, please check if the issue has already been reported
- Use the bug report template when creating an issue
- Include as much relevant information as possible
- Include steps to reproduce the issue

### Suggesting Enhancements

- Open an issue using the feature request template
- Clearly describe the feature and its benefits
- Discuss potential implementation approaches
- Consider the feature's impact on existing functionality

### Development Process

1. Ensure you have all the requirements installed:
   - macOS 14.4 or later
   - Latest version of Xcode
   - Latest version of Swift
   - whisper.cpp properly set up

2. Follow our coding standards:
   - Use Swift style guidelines
   - Write meaningful commit messages
   - Include comments where necessary
   - Add tests for new features

3. Testing:
   - Run existing tests
   - Add new tests for new functionality
   - Ensure all tests pass before submitting PR

## Style Guidelines

- Follow Swift style guidelines
- Use meaningful variable and function names
- Keep functions focused and concise
- Comment complex logic
- Write self-documenting code where possible

## Community

- Join our discussions
- Help other contributors
- Share your ideas
- Be respectful and constructive

## Questions?

If you have any questions or need clarification, feel free to:
1. Open an issue
2. Start a discussion
3. Reach out to the maintainers

Thank you for contributing to VoiceInk! 🎉

## Repository scope

Keep source code, tests, reusable build/evaluation tools, application resources, dependency locks, licenses, and public usage/build instructions in Git.

The `docs/` directory is for local requirements, design proposals, reviews, progress notes, and machine-specific verification records. Keep these files on disk and maintain them alongside related work; they are intentionally ignored. Local agent instructions, recordings, exports, diagnostics, credentials, and generated build/test results are also excluded. Put reusable public guidance in the root documentation rather than linking to ignored process files.

To stop publishing an existing local file, remove it from the Git index with `git rm --cached` and add an ignore rule; do not delete its working copy. Review the commits being pushed as well as the final file tree: ignore rules do not remove files from older commits.
