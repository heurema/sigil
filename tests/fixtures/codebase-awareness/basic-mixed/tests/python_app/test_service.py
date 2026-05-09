import pytest

from python_app.service import format_status, parse_status


def test_parse_status_rejects_unknown_status():
    with pytest.raises(ValueError):
        parse_status("archived")


def test_format_status_normalizes_known_status():
    assert format_status(" active ") == "ACTIVE"
