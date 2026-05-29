#!/usr/bin/env python3
"""Seed deterministic customers for tenant-isolation checks."""

from __future__ import annotations

import os
from decimal import Decimal

import psycopg


DATABASE_URI = os.environ["ADMIN_DATABASE_URI"]

SEED_USERS = [
    {
        "tenant_id": "tenant-a",
        "full_name": "Daan Tenant A",
        "email": "daan.tenant-a@example.test",
        "phone": "+1-555-0101",
        "signup_date": "2026-05-10",
        "city": "Amsterdam",
        "state": "NH",
        "postal_code": "1000AA",
        "country": "NL",
        "order_total": Decimal("4242.01"),
        "payment_method": "card",
    },
    {
        "tenant_id": "tenant-b",
        "full_name": "Michael Tenant B",
        "email": "michael.tenant-b@example.test",
        "phone": "+1-555-0202",
        "signup_date": "2026-05-10",
        "city": "New York",
        "state": "NY",
        "postal_code": "10001",
        "country": "US",
        "order_total": Decimal("4343.02"),
        "payment_method": "paypal",
    },
]


def first_product_id(cursor: psycopg.Cursor) -> int:
    cursor.execute("SELECT id FROM raw_app.products ORDER BY id LIMIT 1")
    row = cursor.fetchone()
    if not row:
        raise RuntimeError("raw_app.products is empty; seed the database first")
    return int(row[0])


def get_segment_id(cursor: psycopg.Cursor, tenant_id: str) -> int:
    cursor.execute(
        "SELECT id FROM raw_app.customer_segments WHERE tenant_id = %s ORDER BY id LIMIT 1",
        [tenant_id],
    )
    row = cursor.fetchone()
    if not row:
        raise RuntimeError(f"No customer_segments found for {tenant_id}")
    return int(row[0])


def upsert_customer(cursor: psycopg.Cursor, user: dict, segment_id: int) -> int:
    cursor.execute(
        """
        INSERT INTO raw_app.customers
            (tenant_id, segment_id, external_ref, full_name, email, phone,
             acquisition_channel, signup_date, status)
        VALUES (%(tenant_id)s, %(segment_id)s, %(external_ref)s, %(full_name)s, %(email)s,
                %(phone)s, %(acquisition_channel)s, %(signup_date)s, %(status)s)
        ON CONFLICT (tenant_id, email) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            phone     = EXCLUDED.phone,
            signup_date = EXCLUDED.signup_date
        RETURNING id
        """,
        {
            **user,
            "segment_id": segment_id,
            "external_ref": f"SEED-{user['tenant_id'].upper()}",
            "acquisition_channel": "direct",
            "status": "active",
        },
    )
    return int(cursor.fetchone()[0])


def upsert_tenant_mapping(cursor: psycopg.Cursor, customer_id: int, tenant_id: str) -> None:
    cursor.execute(
        """
        INSERT INTO tenant_app.customer_tenants (customer_id, tenant_id)
        VALUES (%s, %s)
        ON CONFLICT (customer_id) DO UPDATE
        SET tenant_id = EXCLUDED.tenant_id
        """,
        [customer_id, tenant_id],
    )


def upsert_customer_address(cursor: psycopg.Cursor, customer_id: int, user: dict) -> None:
    cursor.execute(
        """
        UPDATE raw_app.customer_addresses
        SET city = %(city)s, state = %(state)s, country = %(country)s, postal_code = %(postal_code)s
        WHERE customer_id = %(customer_id)s AND address_type = 'billing'
        """,
        {**user, "customer_id": customer_id},
    )
    if cursor.rowcount:
        return
    cursor.execute(
        """
        INSERT INTO raw_app.customer_addresses
            (customer_id, address_type, city, state, country, postal_code, is_default)
        VALUES (%(customer_id)s, 'billing', %(city)s, %(state)s, %(country)s, %(postal_code)s, true)
        """,
        {**user, "customer_id": customer_id},
    )


def upsert_marker_order(
    cursor: psycopg.Cursor, customer_id: int, user: dict, product_id: int
) -> int:
    order_number = f"SEED-{user['tenant_id'].upper()}-001"
    cursor.execute(
        "SELECT id FROM raw_app.orders WHERE order_number = %s",
        [order_number],
    )
    row = cursor.fetchone()
    total = user["order_total"]
    if row:
        order_id = int(row[0])
        cursor.execute(
            "UPDATE raw_app.orders SET status = 'paid', total_amount = %s WHERE id = %s",
            [total, order_id],
        )
    else:
        cursor.execute(
            """
            INSERT INTO raw_app.orders
                (tenant_id, customer_id, order_number, order_ts, status, currency,
                 subtotal_amount, discount_amount, tax_amount, shipping_amount, total_amount)
            VALUES (%s, %s, %s, TIMESTAMP '2026-05-10 12:00:00', 'paid', 'USD', %s, 0, 0, 0, %s)
            RETURNING id
            """,
            [user["tenant_id"], customer_id, order_number, total, total],
        )
        order_id = int(cursor.fetchone()[0])

    cursor.execute("DELETE FROM raw_app.order_lines WHERE order_id = %s", [order_id])
    cursor.execute(
        """
        INSERT INTO raw_app.order_lines (order_id, product_id, quantity, unit_price, unit_cost, discount_amount)
        VALUES (%s, %s, 1, %s, 0, 0)
        """,
        [order_id, product_id, total],
    )

    cursor.execute("DELETE FROM raw_app.payments WHERE order_id = %s", [order_id])
    cursor.execute(
        """
        INSERT INTO raw_app.payments (order_id, payment_ts, payment_method, status, processor, amount)
        VALUES (%s, TIMESTAMP '2026-05-10 12:05:00', %s, 'completed', 'stripe', %s)
        """,
        [order_id, user["payment_method"], total],
    )
    return order_id


def main() -> None:
    with psycopg.connect(DATABASE_URI) as connection:
        with connection.cursor() as cursor:
            product_id = first_product_id(cursor)
            for user in SEED_USERS:
                segment_id = get_segment_id(cursor, user["tenant_id"])
                customer_id = upsert_customer(cursor, user, segment_id)
                upsert_tenant_mapping(cursor, customer_id, str(user["tenant_id"]))
                upsert_customer_address(cursor, customer_id, user)
                order_id = upsert_marker_order(cursor, customer_id, user, product_id)
                print(
                    f"{user['tenant_id']}: customer_id={customer_id}, "
                    f"order_id={order_id}, email={user['email']}"
                )
        connection.commit()


if __name__ == "__main__":
    main()
