### Tool Mandate

- **NEVER use `find` or `grep`** in shell commands. They are slower and produce noisy output.
- **ALWAYS use `fd`** to search for files (faster, ignores .gitignore, colorized output).
- **ALWAYS use `rg` (ripgrep)** to search file contents (faster, respects .gitignore, better filtering).
- This is a hard rule, not a suggestion. Replace any instinct to use `find`/`grep` immediately.


## MCP Servers

Prefer MCP tools over built-in web tools for better results: 

- **Exa MCP** (`exa`): Use for web search and content retrieval. Prefer this for finding specific technical documentation, code examples, or recent information.
- **Jina MCP** (`jina-mcp-server`): Use for reading and summarizing web content. Prefer this when you need to extract or summarize content from a specific URL.

Use MCPs proactively when the task involves:
- Searching for technical documentation or APIs
- Fetching content from specific URLs
- Researching current best practices or recent changes

You'll need first to connect to mcp tools BEFORE USING THEM!!!
`mcp connect jina-mcp-server`

- We're on NixOS
- YOU CANNOT READ IMAGES.
- NEVER ATTEMPT TO READ IMAGES.
- **NEVER use `find` or `grep` in any Bash/ShellSession command. Always use `fd` and `rg` instead.**
