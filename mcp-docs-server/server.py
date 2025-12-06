#!/usr/bin/env python3
"""
MCP Server for Blitz Gateway Documentation Generation

Generates and maintains documentation for the Blitz API Gateway by reading
Zig source files and using LLM sampling to produce human-friendly docs.
"""

import os
import re
from pathlib import Path
from typing import Optional, List, Dict, Any
import json

# MCP imports - adjust based on your MCP SDK version
# The MCP SDK API may vary, so we try multiple import patterns
MCP_AVAILABLE = False
Context = None
Server = None
stdio_server = None
InitializationOptions = None

try:
    # Try Anthropic's MCP SDK
    from mcp.server import Server
    from mcp.server.models import InitializationOptions
    from mcp.types import Tool, TextContent
    from mcp.server.stdio import stdio_server
    from mcp import Context
    MCP_AVAILABLE = True
except ImportError:
    try:
        # Try alternative MCP SDK structure
        from mcp import Server, Tool, TextContent, Context
        from mcp.server.stdio import stdio_server
        InitializationOptions = dict  # Fallback
        MCP_AVAILABLE = True
    except ImportError:
        # MCP not available - can still run in standalone mode for testing
        print("Warning: MCP SDK not found. Running in standalone mode.")
        print("Install with: pip install mcp")
        MCP_AVAILABLE = False

# Initialize MCP server if available
if MCP_AVAILABLE:
    app = Server("blitz-docs-generator")
else:
    app = None

# Project root (assumes server runs from project root)
PROJECT_ROOT = Path(__file__).parent.parent
SRC_DIR = PROJECT_ROOT / "src"
DOCS_DIR = PROJECT_ROOT / "docs"


def read_zig_files(source_path: str) -> str:
    """Read Zig source files from a path (file or directory)."""
    path = Path(source_path)
    
    # If relative path, resolve from project root
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    
    if not path.exists():
        raise FileNotFoundError(f"Path not found: {source_path}")
    
    if path.is_file():
        if path.suffix != ".zig":
            raise ValueError(f"Not a Zig file: {source_path}")
        return path.read_text(encoding="utf-8")
    
    # If directory, read all .zig files recursively
    zig_files = list(path.rglob("*.zig"))
    if not zig_files:
        raise ValueError(f"No Zig files found in: {source_path}")
    
    content_parts = []
    for zig_file in sorted(zig_files):
        relative_path = zig_file.relative_to(PROJECT_ROOT)
        content_parts.append(f"// File: {relative_path}\n")
        content_parts.append(zig_file.read_text(encoding="utf-8"))
        content_parts.append("\n\n")
    
    return "".join(content_parts)


def read_markdown_files(docs_path: str) -> str:
    """Read markdown documentation files from a path."""
    path = Path(docs_path)
    
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    
    if not path.exists():
        return ""  # No docs yet
    
    if path.is_file():
        if path.suffix != ".md":
            raise ValueError(f"Not a markdown file: {docs_path}")
        return path.read_text(encoding="utf-8")
    
    # If directory, read all .md files
    md_files = list(path.rglob("*.md"))
    if not md_files:
        return ""
    
    content_parts = []
    for md_file in sorted(md_files):
        relative_path = md_file.relative_to(PROJECT_ROOT)
        content_parts.append(f"# {relative_path}\n\n")
        content_parts.append(md_file.read_text(encoding="utf-8"))
        content_parts.append("\n\n")
    
    return "".join(content_parts)


def extract_error_definitions(source_path: str) -> str:
    """Extract error code definitions from Zig source files."""
    zig_code = read_zig_files(source_path)
    
    # Look for error enum definitions
    error_patterns = [
        r'pub const \w+Error\s*=\s*error\s*\{[^}]+\}',
        r'pub const ErrorCode\s*=\s*enum[^}]+\}',
        r'error\s*\{[^}]+\}',
    ]
    
    errors = []
    for pattern in error_patterns:
        matches = re.finditer(pattern, zig_code, re.MULTILINE | re.DOTALL)
        for match in matches:
            errors.append(match.group(0))
    
    return "\n\n".join(errors) if errors else "No error definitions found."


def write_doc_file(output_path: str, content: str) -> str:
    """Write documentation content to a file."""
    path = Path(output_path)
    
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    
    # Ensure directory exists
    path.parent.mkdir(parents=True, exist_ok=True)
    
    path.write_text(content, encoding="utf-8")
    return str(path.relative_to(PROJECT_ROOT))


def _generate_api_reference_impl(source_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
    """
    Generate API reference documentation for Zig source files.
    
    Args:
        source_path: Path to Zig file or directory containing Zig files
        output_path: Optional path to write the generated documentation
        ctx: MCP context for sampling
    
    Returns:
        Generated API reference documentation
    """
    zig_code = read_zig_files(source_path)
    
    prompt = f"""Generate API reference documentation for this Zig code.

Include:
- Function signatures with parameters
- Parameter descriptions with types
- Return values and their types
- Error conditions that can occur
- Usage examples where helpful
- Module-level documentation if present

Format as clean markdown with proper headings and code blocks.

Code:
```zig
{zig_code}
```"""

    # Use MCP sampling to generate documentation
    if ctx and hasattr(ctx, 'sample'):
        try:
            if hasattr(ctx.sample, '__call__'):
                response = await ctx.sample(prompt, max_tokens=2000) if hasattr(ctx.sample, '__await__') else ctx.sample(prompt, max_tokens=2000)
                doc_content = response.text if hasattr(response, 'text') else str(response)
            else:
                doc_content = f"# API Reference\n\n```zig\n{zig_code[:1000]}...\n```\n\n*Note: MCP context available but sampling not configured.*"
        except Exception as e:
            doc_content = f"# API Reference\n\n```zig\n{zig_code[:1000]}...\n```\n\n*Note: Error during LLM sampling: {e}*"
    else:
        # Fallback if no context (for testing)
        doc_content = f"# API Reference\n\n```zig\n{zig_code[:1000]}...\n```\n\n*Note: LLM sampling not available. Install MCP SDK and connect to an LLM.*"
    
    # Write to file if output path provided
    if output_path:
        file_path = write_doc_file(output_path, doc_content)
        return f"Generated API reference written to: {file_path}\n\n{doc_content}"
    
    return doc_content


if MCP_AVAILABLE:
    @app.tool()
    async def generate_api_reference(source_path: str, output_path: Optional[str] = None, ctx: Context = None) -> str:
        return _generate_api_reference_impl(source_path, output_path, ctx)
else:
    def generate_api_reference(source_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
        return _generate_api_reference_impl(source_path, output_path, ctx)


def _generate_quickstart_impl(source_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
    """
    Generate a quickstart guide for new users.
    
    Args:
        source_path: Path to main Zig file or directory (e.g., src/main.zig)
        output_path: Optional path to write the generated documentation
        ctx: MCP context for sampling
    
    Returns:
        Generated quickstart guide
    """
    zig_code = read_zig_files(source_path)
    
    prompt = f"""Write a quickstart guide for this API gateway.

Assume the reader:
- Knows HTTP/REST basics
- Has never used this gateway before
- Wants to see it working in under 5 minutes

Include:
- Installation instructions
- Basic configuration
- How to start the server
- A simple example request/response
- Common next steps

Make it practical and copy-paste friendly.

Code:
```zig
{zig_code}
```"""

    if ctx and hasattr(ctx, 'sample'):
        try:
            if hasattr(ctx.sample, '__call__'):
                response = await ctx.sample(prompt, max_tokens=1500) if hasattr(ctx.sample, '__await__') else ctx.sample(prompt, max_tokens=1500)
                doc_content = response.text if hasattr(response, 'text') else str(response)
            else:
                doc_content = f"# Quickstart Guide\n\n*Note: MCP context available but sampling not configured.*"
        except Exception as e:
            doc_content = f"# Quickstart Guide\n\n*Note: Error during LLM sampling: {e}*"
    else:
        doc_content = f"# Quickstart Guide\n\n*Note: LLM sampling not available. Install MCP SDK and connect to an LLM.*"
    
    if output_path:
        file_path = write_doc_file(output_path, doc_content)
        return f"Generated quickstart guide written to: {file_path}\n\n{doc_content}"
    
    return doc_content


if MCP_AVAILABLE:
    @app.tool()
    async def generate_quickstart(source_path: str, output_path: Optional[str] = None, ctx: Context = None) -> str:
        return _generate_quickstart_impl(source_path, output_path, ctx)
else:
    def generate_quickstart(source_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
        return _generate_quickstart_impl(source_path, output_path, ctx)


def _generate_config_docs_impl(config_schema_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
    """
    Generate documentation for configuration options.
    
    Args:
        config_schema_path: Path to config file (e.g., lb.example.toml) or config module
        output_path: Optional path to write the generated documentation
        ctx: MCP context for sampling
    
    Returns:
        Generated configuration documentation
    """
    # Try to read as config file first
    config_path = Path(config_schema_path)
    if not config_path.is_absolute():
        config_path = PROJECT_ROOT / config_path
    
    if config_path.exists() and config_path.suffix in [".toml", ".yaml", ".yml"]:
        schema = config_path.read_text(encoding="utf-8")
    else:
        # Try reading from config module
        config_code = read_zig_files("src/config/mod.zig")
        schema = config_code
    
    prompt = f"""Document these configuration options.

For each option include:
- What it does (one clear sentence)
- Type and default value
- Example usage
- Common mistakes to avoid
- When you'd want to change it

Format as a reference guide with clear sections.

Schema/Code:
```
{schema}
```"""

    if ctx and hasattr(ctx, 'sample'):
        try:
            if hasattr(ctx.sample, '__call__'):
                response = await ctx.sample(prompt, max_tokens=2000) if hasattr(ctx.sample, '__await__') else ctx.sample(prompt, max_tokens=2000)
                doc_content = response.text if hasattr(response, 'text') else str(response)
            else:
                doc_content = f"# Configuration Reference\n\n```\n{schema[:1000]}...\n```\n\n*Note: MCP context available but sampling not configured.*"
        except Exception as e:
            doc_content = f"# Configuration Reference\n\n*Note: Error during LLM sampling: {e}*"
    else:
        doc_content = f"# Configuration Reference\n\n```\n{schema[:1000]}...\n```\n\n*Note: LLM sampling not available. Install MCP SDK and connect to an LLM.*"
    
    if output_path:
        file_path = write_doc_file(output_path, doc_content)
        return f"Generated config docs written to: {file_path}\n\n{doc_content}"
    
    return doc_content


if MCP_AVAILABLE:
    @app.tool()
    async def generate_config_docs(config_schema_path: str, output_path: Optional[str] = None, ctx: Context = None) -> str:
        return _generate_config_docs_impl(config_schema_path, output_path, ctx)
else:
    def generate_config_docs(config_schema_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
        return _generate_config_docs_impl(config_schema_path, output_path, ctx)


def _explain_error_impl(error_code: str, source_path: str = "src", ctx: Any = None) -> str:
    """
    Generate user-friendly explanation for an error code.
    
    Args:
        error_code: The error code name to explain (e.g., "NoBackendsAvailable")
        source_path: Path to source files to search for error definitions
        ctx: MCP context for sampling
    
    Returns:
        User-friendly error explanation
    """
    error_handling_code = extract_error_definitions(source_path)
    
    prompt = f"""Explain error code "{error_code}" for an end user.

Include:
- What went wrong (plain language)
- Why it might have happened (common causes)
- How to fix it (actionable steps)
- Prevention tips if applicable

Write in a friendly, helpful tone. Assume the user is not a Zig expert.

Error definitions:
```zig
{error_handling_code}
```"""

    if ctx and hasattr(ctx, 'sample'):
        try:
            if hasattr(ctx.sample, '__call__'):
                response = await ctx.sample(prompt, max_tokens=500) if hasattr(ctx.sample, '__await__') else ctx.sample(prompt, max_tokens=500)
                doc_content = response.text if hasattr(response, 'text') else str(response)
            else:
                doc_content = f"# Error: {error_code}\n\n*Note: MCP context available but sampling not configured.*"
        except Exception as e:
            doc_content = f"# Error: {error_code}\n\n*Note: Error during LLM sampling: {e}*"
    else:
        doc_content = f"# Error: {error_code}\n\n*Note: LLM sampling not available. Install MCP SDK and connect to an LLM.*\n\n```zig\n{error_handling_code[:500]}...\n```"
    
    return doc_content


if MCP_AVAILABLE:
    @app.tool()
    async def explain_error(error_code: str, source_path: str = "src", ctx: Context = None) -> str:
        return _explain_error_impl(error_code, source_path, ctx)
else:
    def explain_error(error_code: str, source_path: str = "src", ctx: Any = None) -> str:
        return _explain_error_impl(error_code, source_path, ctx)


def _sync_docs_impl(source_path: str, docs_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
    """
    Compare documentation against source code and identify what's outdated.
    
    Args:
        source_path: Path to source files to analyze
        docs_path: Path to existing documentation
        output_path: Optional path to write the sync report
        ctx: MCP context for sampling
    
    Returns:
        Sync report identifying outdated documentation
    """
    zig_code = read_zig_files(source_path)
    current_docs = read_markdown_files(docs_path)
    
    prompt = f"""Compare this documentation against the source code.

Identify:
- Documented features that no longer exist in the code
- New features missing from the documentation
- Descriptions that don't match the current implementation
- Outdated examples or code snippets
- Missing error handling documentation

Provide a prioritized list with specific file/function references.

Source code:
```zig
{zig_code[:5000]}  # Truncated for context
```

Current docs:
```markdown
{current_docs[:5000]}  # Truncated for context
```"""

    if ctx and hasattr(ctx, 'sample'):
        try:
            if hasattr(ctx.sample, '__call__'):
                response = await ctx.sample(prompt, max_tokens=1000) if hasattr(ctx.sample, '__await__') else ctx.sample(prompt, max_tokens=1000)
                report = response.text if hasattr(response, 'text') else str(response)
            else:
                report = f"# Documentation Sync Report\n\n*Note: MCP context available but sampling not configured.*\n\nSource: {source_path}\nDocs: {docs_path}"
        except Exception as e:
            report = f"# Documentation Sync Report\n\n*Note: Error during LLM sampling: {e}*"
    else:
        report = f"# Documentation Sync Report\n\n*Note: LLM sampling not available. Install MCP SDK and connect to an LLM.*\n\nSource: {source_path}\nDocs: {docs_path}"
    
    if output_path:
        file_path = write_doc_file(output_path, report)
        return f"Sync report written to: {file_path}\n\n{report}"
    
    return report


if MCP_AVAILABLE:
    @app.tool()
    async def sync_docs(source_path: str, docs_path: str, output_path: Optional[str] = None, ctx: Context = None) -> str:
        return _sync_docs_impl(source_path, docs_path, output_path, ctx)
else:
    def sync_docs(source_path: str, docs_path: str, output_path: Optional[str] = None, ctx: Any = None) -> str:
        return _sync_docs_impl(source_path, docs_path, output_path, ctx)


def main():
    """Run the MCP server."""
    if not MCP_AVAILABLE:
        print("Error: MCP SDK not available. Cannot run as MCP server.")
        print("Install with: pip install mcp")
        print("\nYou can still use the functions directly in Python:")
        print("  from server import generate_api_reference")
        print("  result = generate_api_reference('src/main.zig')")
        return
    
    # Run server over stdio
    init_options = InitializationOptions(
        server_name="blitz-docs-generator",
        server_version="0.1.0",
    ) if InitializationOptions != dict else {
        "server_name": "blitz-docs-generator",
        "server_version": "0.1.0",
    }
    
    with stdio_server() as (read_stream, write_stream):
        app.run(
            read_stream=read_stream,
            write_stream=write_stream,
            initialization_options=init_options,
        )


if __name__ == "__main__":
    main()

