"""Vulture whitelist for false positive suppression.

Add unused-looking names here that are actually used dynamically.
Common examples:
- pytest fixtures (used by dependency injection)
- Django signals, admin classes
- __all__ exports
- Celery tasks registered by decorator
- Click/Typer CLI commands

Format: one Python expression per line.
Vulture checks that each name exists in the codebase.

See: https://github.com/jendrikseipp/vulture
"""
