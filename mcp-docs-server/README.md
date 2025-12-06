# Blitz Docs Generator

An MCP (Model Context Protocol) server that generates and maintains documentation for the Blitz API Gateway by reading Zig source files and using LLM sampling to produce human-friendly documentation.

## Overview

This tool automates documentation generation for the Blitz Gateway project. It uses MCP sampling to analyze Zig source code and generate:

- **API Reference** - Technical documentation for functions, types, and modules
- **Quickstart Guides** - Getting-started tutorials for new users
- **Configuration Docs** - Complete reference for all config options
- **Error Explanations** - User-friendly error code documentation
- **Sync Reports** - Identify outdated or missing documentation

## Installation

```bash
cd mcp-docs-server
pip install -r requirements.txt
```

**Note:** You'll need to install the appropriate MCP SDK. The exact package name may vary depending on your MCP implementation. Common options:

- `pip install mcp` (official SDK)
- `pip install anthropic-mcp` (Anthropic's implementation)

## Usage

### Testing Without MCP

You can test the functions directly without an MCP connection:

```bash
python example_usage.py
```

This will generate documentation using fallback mode (no LLM sampling, but file reading/writing works).

### Running the MCP Server

The server runs over stdio and communicates via the MCP protocol:

```bash
python server.py
```

**Note:** The server requires an MCP SDK and LLM connection for full functionality. Without it, the tools will still work but generate placeholder documentation.

### Using with MCP Clients

Connect to this server from your MCP client (e.g., Claude Desktop, Cursor, etc.) and use the tools:

#### Generate API Reference

```
generate_api_reference(
  source_path: "src/router.zig",
  output_path: "docs/reference/router.md"
)
```

#### Generate Quickstart

```
generate_quickstart(
  source_path: "src/main.zig",
  output_path: "docs/quickstart.md"
)
```

#### Generate Config Docs

```
generate_config_docs(
  config_schema_path: "lb.example.toml",
  output_path: "docs/configuration.md"
)
```

#### Explain an Error

```
explain_error(
  error_code: "NoBackendsAvailable",
  source_path: "src/load_balancer"
)
```

#### Sync Documentation

```
sync_docs(
  source_path: "src",
  docs_path: "docs",
  output_path: "docs/sync-report.md"
)
```

## Tools

### `generate_api_reference`

Scans Zig source files and produces technical reference documentation with:
- Function signatures
- Parameter descriptions
- Return values
- Error conditions
- Usage examples

### `generate_quickstart`

Creates a getting-started guide assuming:
- Reader knows HTTP/REST basics
- First-time user
- Wants to see it working in under 5 minutes

### `generate_config_docs`

Documents all configuration options with:
- What each option does
- Type and default value
- Example usage
- Common mistakes

### `explain_error`

Generates user-friendly explanations for error codes including:
- What went wrong
- Why it might have happened
- How to fix it

### `sync_docs`

Compares current docs against source code and identifies:
- Documented features that no longer exist
- New features missing from docs
- Descriptions that don't match implementation

## File Structure

```
blitz-gateway/
├── src/                    # Zig source files
├── docs/                   # Generated documentation
│   ├── reference/         # API reference docs
│   ├── quickstart.md      # Quickstart guide
│   └── configuration.md   # Config documentation
└── mcp-docs-server/
    ├── server.py          # MCP server implementation
    ├── requirements.txt   # Python dependencies
    └── README.md          # This file
```

## Configuration

The server assumes it's running from the project root. Source files are resolved relative to the project root.

To change paths, modify the constants at the top of `server.py`:

```python
PROJECT_ROOT = Path(__file__).parent.parent
SRC_DIR = PROJECT_ROOT / "src"
DOCS_DIR = PROJECT_ROOT / "docs"
```

## Workflow

1. Developer writes Zig code
2. Asks MCP client: "generate docs for src/router.zig"
3. MCP server reads source files
4. LLM sampling generates documentation
5. Markdown files written to `/docs`
6. Developer reviews and commits

## Testing

Run the example script to test all functions:

```bash
cd mcp-docs-server
python example_usage.py
```

This will:
1. Generate API reference for `src/main.zig`
2. Generate quickstart guide
3. Generate config documentation
4. Explain an error code
5. Sync documentation

All output files will be written to the `docs/` directory.

## Limitations

- Requires an MCP-compatible LLM connection for full functionality
- Documentation quality depends on LLM capabilities
- May need manual review and editing
- Zig-specific syntax may need refinement
- Without MCP/LLM, generates placeholder documentation (useful for testing file I/O)

## Contributing

When adding new tools or features:

1. Add the tool function with `@app.tool()` decorator
2. Use `ctx.sample()` for LLM generation
3. Update this README with usage examples
4. Test with actual Zig source files

## License

Same as Blitz Gateway (Apache 2.0)

