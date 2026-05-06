import importlib.util
import os
import sys
from pathlib import Path


def load_server_module(tmp_path):
    os.environ["OMI_LOCAL_API_DB_PATH"] = str(tmp_path / "omi-local-test.db")
    module_path = Path(__file__).with_name("server.py")
    spec = importlib.util.spec_from_file_location("omi_local_api_server_test", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def test_loopback_host_detection(tmp_path):
    server = load_server_module(tmp_path)

    assert server.is_loopback_host("127.0.0.1")
    assert server.is_loopback_host("::1")
    assert server.is_loopback_host("localhost")
    assert not server.is_loopback_host("192.168.1.50")
    assert not server.is_loopback_host("attacker.example.com")


def test_cors_allows_only_loopback_origins(tmp_path):
    server = load_server_module(tmp_path)

    assert server.cors_allowed_origin("http://127.0.0.1:10201") == "http://127.0.0.1:10201"
    assert server.cors_allowed_origin("http://localhost:3000") == "http://localhost:3000"
    assert server.cors_allowed_origin("https://attacker.example.com") is None
    assert server.cors_allowed_origin("http://192.168.1.50:10201") is None
    assert server.cors_allowed_origin("null") is None
