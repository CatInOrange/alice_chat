from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from backend.app.store.db import DbConfig, connect


class DbConnectionTests(unittest.TestCase):
    def test_connect_closes_connection_after_context_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db = DbConfig(path=Path(temp_dir) / "lunaria.sqlite3")

            with connect(db) as conn:
                conn.execute("SELECT 1")

            with self.assertRaises(sqlite3.ProgrammingError):
                conn.execute("SELECT 1")


if __name__ == "__main__":
    unittest.main()
