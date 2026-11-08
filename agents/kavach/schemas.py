"""JSON Schema validation for every workflow output and model step (shared/schemas/)."""
from __future__ import annotations

import json
from functools import lru_cache
from typing import Any

from jsonschema import Draft202012Validator

from .config import SCHEMAS_DIR


class SchemaError(ValueError):
    pass


@lru_cache(maxsize=None)
def _validator(name: str) -> Draft202012Validator:
    path = SCHEMAS_DIR / f"{name}.json"
    schema = json.loads(path.read_text())
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def validate(name: str, obj: Any) -> Any:
    errors = sorted(_validator(name).iter_errors(obj), key=lambda e: list(e.path))
    if errors:
        e = errors[0]
        raise SchemaError(f"{name}: {'/'.join(map(str, e.path)) or '<root>'}: {e.message}")
    return obj


def is_valid(name: str, obj: Any) -> bool:
    try:
        validate(name, obj)
        return True
    except SchemaError:
        return False


def all_schema_names() -> list[str]:
    return sorted(p.stem for p in SCHEMAS_DIR.glob("*.json"))
