#!/usr/bin/env python3

"""
scripts/ci/check_api_compatibility.py

Detects breaking changes in the API surface
"""

import json
import sys
import argparse
from typing import List, Dict, Any
from dataclasses import dataclass


@dataclass
class BreakingChange:
    type: str
    severity: str
    description: str
    migration_hint: str


def load_api_manifest(path: str) -> Dict[str, Any]:
    """Load API manifest JSON"""
    with open(path, 'r') as f:
        return json.load(f)


def check_function_compatibility(base: Dict, current: Dict) -> List[BreakingChange]:
    """Check for function signature changes"""
    changes = []
    
    base_funcs = {f['name']: f for f in base.get('functions', [])}
    current_funcs = {f['name']: f for f in current.get('functions', [])}
    
    # Removed functions
    for name in base_funcs:
        if name not in current_funcs:
            changes.append(BreakingChange(
                type='function_removed',
                severity='critical',
                description=f"Function '{name}' was removed",
                migration_hint=f"Find alternative for {name} or restore function"
            ))
    
    # Modified functions
    for name in base_funcs:
        if name in current_funcs:
            base_sig = base_funcs[name].get('signature')
            curr_sig = current_funcs[name].get('signature')
            
            if base_sig != curr_sig:
                changes.append(BreakingChange(
                    type='function_signature_changed',
                    severity='critical',
                    description=f"Function '{name}' signature changed",
                    migration_hint=f"Update all calls to {name} to match new signature"
                ))
    
    return changes


def check_struct_compatibility(base: Dict, current: Dict) -> List[BreakingChange]:
    """Check for struct/type changes"""
    changes = []
    
    base_structs = {s['name']: s for s in base.get('structs', [])}
    current_structs = {s['name']: s for s in current.get('structs', [])}
    
    # Removed structs
    for name in base_structs:
        if name not in current_structs:
            changes.append(BreakingChange(
                type='struct_removed',
                severity='critical',
                description=f"Struct '{name}' was removed",
                migration_hint=f"Find alternative for {name}"
            ))
    
    # Field changes
    for name in base_structs:
        if name in current_structs:
            base_fields = set(f['name'] for f in base_structs[name].get('fields', []))
            curr_fields = set(f['name'] for f in current_structs[name].get('fields', []))
            
            removed_fields = base_fields - curr_fields
            if removed_fields:
                changes.append(BreakingChange(
                    type='struct_field_removed',
                    severity='high',
                    description=f"Struct '{name}' lost fields: {removed_fields}",
                    migration_hint=f"Remove usage of fields: {removed_fields}"
                ))
    
    return changes


def check_config_compatibility(base: Dict, current: Dict) -> List[BreakingChange]:
    """Check for configuration schema changes"""
    changes = []
    
    base_config = base.get('config_schema', {})
    current_config = current.get('config_schema', {})
    
    # Check removed required fields
    base_required = set(base_config.get('required', []))
    curr_required = set(current_config.get('required', []))
    
    new_required = curr_required - base_required
    if new_required:
        changes.append(BreakingChange(
            type='config_new_required_field',
            severity='high',
            description=f"New required config fields: {new_required}",
            migration_hint=f"Add required fields to configuration: {new_required}"
        ))
    
    return changes


def main():
    parser = argparse.ArgumentParser(description='Check API compatibility')
    parser.add_argument('--base', required=True, help='Base API manifest')
    parser.add_argument('--current', required=True, help='Current API manifest')
    parser.add_argument('--output', required=True, help='Output JSON file')
    args = parser.parse_args()
    
    base_api = load_api_manifest(args.base)
    current_api = load_api_manifest(args.current)
    
    breaking_changes = []
    breaking_changes.extend(check_function_compatibility(base_api, current_api))
    breaking_changes.extend(check_struct_compatibility(base_api, current_api))
    breaking_changes.extend(check_config_compatibility(base_api, current_api))
    
    # Write results
    with open(args.output, 'w') as f:
        json.dump([{
            'type': c.type,
            'severity': c.severity,
            'description': c.description,
            'migration_hint': c.migration_hint
        } for c in breaking_changes], f, indent=2)
    
    # Exit with error if breaking changes found
    if breaking_changes:
        print(f"Found {len(breaking_changes)} breaking changes:")
        for change in breaking_changes:
            print(f"  [{change.severity}] {change.description}")
        sys.exit(1)
    else:
        print("No breaking changes detected")
        sys.exit(0)


if __name__ == '__main__':
    main()

