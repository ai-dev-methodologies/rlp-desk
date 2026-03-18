# Contributing to RLP Desk

Thanks for your interest in contributing! RLP Desk is a fresh-context iterative loop system for Claude Code, and we welcome contributions that improve the protocol, documentation, and examples.

## How to Contribute

### Reporting Issues

- Use [GitHub Issues](https://github.com/ai-dev-methodologies/rlp-desk/issues) to report bugs or suggest features
- Include your Claude Code version and OS
- For protocol issues, describe the iteration behavior you expected vs. what happened

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Make your changes
4. Test the install script: `bash install.sh`
5. If you changed the slash command or governance, test a full loop cycle
6. Commit with a clear message
7. Open a PR against `main`

## What to Contribute

### High-Value Contributions

- **Examples**: New project examples showing RLP Desk in different contexts (web apps, CLI tools, refactoring tasks)
- **Documentation**: Improvements to getting-started guide, architecture docs, or protocol reference
- **Bug fixes**: Issues with the init script, slash command parsing, or protocol edge cases

### Guidelines

- All user-facing text must be in English
- Do not change the core protocol (Leader/Worker/Verifier roles, sentinel ownership, fresh-context guarantees) without an RFC discussion in Issues first
- Keep the install script idempotent
- Examples should be self-contained and include a complete PRD + test spec

## Project Structure

```
rlp-desk/
├── src/
│   ├── commands/rlp-desk.md      # The slash command (installed to ~/.claude/commands/)
│   ├── scripts/init_ralph_desk.zsh  # Scaffold generator
│   └── governance.md             # Core protocol document
├── examples/                     # Example projects
├── docs/                         # Documentation
└── install.sh                    # One-line installer
```

## Code of Conduct

Be respectful. Focus on the work. Assume good intent.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](../LICENSE).
