#!/usr/bin/env python3
"""Verify ecommerce tenant views isolate rows and block direct base-table reads."""

from __future__ import annotations

import os

import psycopg


DATABASE_URI = os.environ["DATABASE_URI"]


def count_for_tenant(cursor: psycopg.Cursor, tenant_id: str, relation: str) -> int:
    cursor.execute("SELECT set_config('app.tenant_id', %s, true)", [tenant_id])
    cursor.execute(f"SELECT count(*) FROM tenant_app.{relation}")
    return int(cursor.fetchone()[0])


def marker_emails_for_tenant(cursor: psycopg.Cursor, tenant_id: str) -> list[str]:
    cursor.execute("SELECT set_config('app.tenant_id', %s, true)", [tenant_id])
    cursor.execute(
        """
        SELECT email
        FROM tenant_app.customers
        WHERE email IN ('daan.tenant-a@example.test', 'michael.tenant-b@example.test')
        ORDER BY email
        """
    )
    return [str(row[0]) for row in cursor.fetchall()]


def main() -> None:
    with psycopg.connect(DATABASE_URI) as connection:
        with connection.cursor() as cursor:
            cursor.execute("BEGIN READ ONLY")
            print(f"tenant-a customers: {count_for_tenant(cursor, 'tenant-a', 'customers')}")
            print(f"tenant-a orders:    {count_for_tenant(cursor, 'tenant-a', 'orders')}")
            print(f"tenant-b customers: {count_for_tenant(cursor, 'tenant-b', 'customers')}")
            print(f"tenant-b orders:    {count_for_tenant(cursor, 'tenant-b', 'orders')}")

            tenant_a_markers = marker_emails_for_tenant(cursor, "tenant-a")
            tenant_b_markers = marker_emails_for_tenant(cursor, "tenant-b")
            print(f"tenant-a markers: {tenant_a_markers}")
            print(f"tenant-b markers: {tenant_b_markers}")

            if tenant_a_markers != ["daan.tenant-a@example.test"]:
                raise RuntimeError("tenant-a marker visibility is incorrect")
            if tenant_b_markers != ["michael.tenant-b@example.test"]:
                raise RuntimeError("tenant-b marker visibility is incorrect")

            try:
                cursor.execute("SELECT count(*) FROM raw_app.customers")
            except Exception as exc:
                print(f"raw_app.customers blocked: {exc.__class__.__name__}")
            else:
                raise RuntimeError("tenant_app_ro can read raw_app.customers directly")


if __name__ == "__main__":
    main()
