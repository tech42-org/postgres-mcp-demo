#!/usr/bin/env python3
"""Create view-only tenant isolation objects for the ecommerce demo database."""

from __future__ import annotations

import os

import psycopg
from psycopg import sql


TENANT_ROLE = os.environ.get("TENANT_ROLE", "tenant_app_ro")
TENANT_ROLE_PASSWORD = os.environ["TENANT_ROLE_PASSWORD"]
DATABASE_URI = os.environ["ADMIN_DATABASE_URI"]


VIEW_GRANTS = [
    "customers",
    "orders",
    "order_lines",
    "payments",
    "products",
    "categories",
    "reviews",
    "customer_addresses",
    "promotions",
    "order_promotions",
    "inventory_snapshots",
    "suppliers",
]


def main() -> None:
    with psycopg.connect(DATABASE_URI, autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute("CREATE SCHEMA IF NOT EXISTS tenant_app")
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS tenant_app.customer_tenants (
                    customer_id INTEGER PRIMARY KEY REFERENCES raw_app.customers(id),
                    tenant_id TEXT NOT NULL
                )
                """
            )
            # raw_app.customers already carries tenant_id — mirror it into the
            # mapping table so the views below have a single join point.
            cursor.execute(
                """
                INSERT INTO tenant_app.customer_tenants (customer_id, tenant_id)
                SELECT id, tenant_id
                FROM raw_app.customers
                ON CONFLICT (customer_id) DO NOTHING
                """
            )

            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.customers AS
                SELECT c.*
                FROM raw_app.customers AS c
                WHERE c.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.orders AS
                SELECT o.*
                FROM raw_app.orders AS o
                WHERE o.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.order_lines AS
                SELECT ol.*
                FROM raw_app.order_lines AS ol
                INNER JOIN raw_app.orders AS o ON o.id = ol.order_id
                WHERE o.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.payments AS
                SELECT p.*
                FROM raw_app.payments AS p
                INNER JOIN raw_app.orders AS o ON o.id = p.order_id
                WHERE o.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.products AS
                SELECT DISTINCT p.*
                FROM raw_app.products AS p
                INNER JOIN raw_app.order_lines AS ol ON ol.product_id = p.id
                INNER JOIN raw_app.orders AS o ON o.id = ol.order_id
                WHERE o.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.categories AS
                SELECT DISTINCT c.*
                FROM raw_app.categories AS c
                INNER JOIN tenant_app.products AS p ON p.category_id = c.id
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.reviews AS
                SELECT r.*
                FROM raw_app.reviews AS r
                WHERE r.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.customer_addresses AS
                SELECT ca.*
                FROM raw_app.customer_addresses AS ca
                INNER JOIN raw_app.customers AS c ON c.id = ca.customer_id
                WHERE c.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.order_promotions AS
                SELECT op.*
                FROM raw_app.order_promotions AS op
                INNER JOIN raw_app.orders AS o ON o.id = op.order_id
                WHERE o.tenant_id = current_setting('app.tenant_id', true)
                """
            )
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.promotions AS
                SELECT DISTINCT p.*
                FROM raw_app.promotions AS p
                INNER JOIN tenant_app.order_promotions AS op ON op.promotion_id = p.id
                """
            )
            # inventory_snapshots links to products; reach the tenant filter
            # through the tenant_app.products view (already tenant-scoped).
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.inventory_snapshots AS
                SELECT DISTINCT i.*
                FROM raw_app.inventory_snapshots AS i
                INNER JOIN tenant_app.products AS p ON p.id = i.product_id
                """
            )
            # suppliers link through products, not inventory_snapshots.
            cursor.execute(
                """
                CREATE OR REPLACE VIEW tenant_app.suppliers AS
                SELECT DISTINCT s.*
                FROM raw_app.suppliers AS s
                INNER JOIN tenant_app.products AS p ON p.supplier_id = s.id
                """
            )

            role_exists = cursor.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", [TENANT_ROLE]
            ).fetchone()
            if role_exists:
                cursor.execute(
                    sql.SQL(
                        "ALTER ROLE {} WITH LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
                    ).format(sql.Identifier(TENANT_ROLE), sql.Literal(TENANT_ROLE_PASSWORD))
                )
            else:
                cursor.execute(
                    sql.SQL(
                        "CREATE ROLE {} LOGIN PASSWORD {} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"
                    ).format(sql.Identifier(TENANT_ROLE), sql.Literal(TENANT_ROLE_PASSWORD))
                )

            for schema in ("public", "raw_app", "analytics_app", "tenant_app"):
                cursor.execute(
                    sql.SQL("REVOKE ALL ON SCHEMA {} FROM {}").format(
                        sql.Identifier(schema), sql.Identifier(TENANT_ROLE)
                    )
                )
                cursor.execute(
                    sql.SQL("REVOKE ALL ON ALL TABLES IN SCHEMA {} FROM {}").format(
                        sql.Identifier(schema), sql.Identifier(TENANT_ROLE)
                    )
                )

            cursor.execute(
                sql.SQL("GRANT USAGE ON SCHEMA tenant_app TO {}").format(sql.Identifier(TENANT_ROLE))
            )
            for view_name in VIEW_GRANTS:
                cursor.execute(
                    sql.SQL("GRANT SELECT ON {}.{} TO {}").format(
                        sql.Identifier("tenant_app"),
                        sql.Identifier(view_name),
                        sql.Identifier(TENANT_ROLE),
                    )
                )

            cursor.execute(
                "SELECT tenant_id, count(*) FROM tenant_app.customer_tenants GROUP BY tenant_id ORDER BY tenant_id"
            )
            for tenant_id, customer_count in cursor.fetchall():
                print(f"{tenant_id}: {customer_count} customers")


if __name__ == "__main__":
    main()
