#!/usr/bin/env python3
"""
Example usage of the Blitz Docs Generator

This script demonstrates how to use the documentation generation functions
directly without MCP, useful for testing and CI/CD pipelines.
"""

import sys
from pathlib import Path

# Add the server module to path
sys.path.insert(0, str(Path(__file__).parent))

from server import (
    generate_api_reference,
    generate_quickstart,
    generate_config_docs,
    explain_error,
    sync_docs,
)


def main():
    """Example usage of documentation generation functions."""
    
    print("=" * 60)
    print("Blitz Docs Generator - Example Usage")
    print("=" * 60)
    print()
    
    # Example 1: Generate API reference for main.zig
    print("Example 1: Generating API reference for src/main.zig")
    print("-" * 60)
    try:
        result = generate_api_reference(
            source_path="src/main.zig",
            output_path="docs/reference/main.md"
        )
        print(f"✓ Generated API reference")
        print(f"  Preview: {result[:200]}...")
    except Exception as e:
        print(f"✗ Error: {e}")
    print()
    
    # Example 2: Generate quickstart guide
    print("Example 2: Generating quickstart guide")
    print("-" * 60)
    try:
        result = generate_quickstart(
            source_path="src/main.zig",
            output_path="docs/quickstart.md"
        )
        print(f"✓ Generated quickstart guide")
        print(f"  Preview: {result[:200]}...")
    except Exception as e:
        print(f"✗ Error: {e}")
    print()
    
    # Example 3: Generate config documentation
    print("Example 3: Generating configuration documentation")
    print("-" * 60)
    try:
        result = generate_config_docs(
            config_schema_path="lb.example.toml",
            output_path="docs/configuration.md"
        )
        print(f"✓ Generated config docs")
        print(f"  Preview: {result[:200]}...")
    except Exception as e:
        print(f"✗ Error: {e}")
    print()
    
    # Example 4: Explain an error
    print("Example 4: Explaining error code")
    print("-" * 60)
    try:
        result = explain_error(
            error_code="NoBackendsAvailable",
            source_path="src/load_balancer"
        )
        print(f"✓ Generated error explanation")
        print(f"  Preview: {result[:200]}...")
    except Exception as e:
        print(f"✗ Error: {e}")
    print()
    
    # Example 5: Sync documentation
    print("Example 5: Syncing documentation")
    print("-" * 60)
    try:
        result = sync_docs(
            source_path="src",
            docs_path="docs",
            output_path="docs/sync-report.md"
        )
        print(f"✓ Generated sync report")
        print(f"  Preview: {result[:200]}...")
    except Exception as e:
        print(f"✗ Error: {e}")
    print()
    
    print("=" * 60)
    print("Note: These examples run without LLM sampling.")
    print("For full functionality, connect to an MCP-compatible LLM.")
    print("=" * 60)


if __name__ == "__main__":
    main()

