# coding: utf-8
"""Hand-written convenience facade over the generated Grobase client.

This is the **reference pattern** for the polyglot SDKs: a thin, importable wrapper
that gives the raw OpenAPI-generated `grobase` package a small, Supabase-shaped
surface (`Client(base_url, api_key)` + `.auth.sign_in()/sign_up()` +
`.from_(table).select()/insert()/delete()`), mirroring the first-class
`@mini-baas/js` SDK.

It is intentionally minimal — it does NOT cover the full generated API surface.
For anything beyond auth + basic CRUD, use the generated `AuthApi` / `RestApi` /
`QueryApi` / `StorageApi` / `FunctionsApi` classes directly (see the README).

Unlike `@mini-baas/js`, this facade is not feature-complete and is considered
experimental.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from grobase.api.auth_api import AuthApi
from grobase.api.rest_api import RestApi
from grobase.api_client import ApiClient
from grobase.configuration import Configuration
from grobase.models.session import Session
from grobase.models.sign_up_request import SignUpRequest
from grobase.models.token_request import TokenRequest

__all__ = ["Client", "AuthClient", "QueryBuilder"]


class QueryBuilder:
    """A tiny PostgREST-style builder bound to one table.

    Wraps the generated ``RestApi`` for the common read/write operations. Only
    the parameters the generated client genuinely exposes are supported
    (``select`` / ``order`` / ``limit`` / ``offset`` on reads); for richer
    PostgREST filters use the generated ``RestApi`` directly.
    """

    def __init__(self, rest: RestApi, table: str) -> None:
        self._rest = rest
        self._table = table

    def select(
        self,
        columns: str = "*",
        *,
        order: Optional[str] = None,
        limit: Optional[int] = None,
        offset: Optional[int] = None,
    ) -> List[Any]:
        """Read rows from the table (`GET /rest/v1/{table}`)."""
        return self._rest.rest_select(
            resource=self._table,
            select=columns,
            order=order,
            limit=limit,
            offset=offset,
        )

    def insert(self, row: Dict[str, Any]) -> None:
        """Insert one row (`POST /rest/v1/{table}`)."""
        return self._rest.rest_insert(resource=self._table, request_body=row)

    def delete(self) -> None:
        """Delete rows matching the table's request filter (`DELETE /rest/v1/{table}`)."""
        return self._rest.rest_delete(resource=self._table)


class AuthClient:
    """Auth surface mirroring `@mini-baas/js`'s `.auth`."""

    def __init__(self, api: AuthApi) -> None:
        self._api = api

    def sign_in(self, email: str, password: str) -> Session:
        """Exchange email + password for a session (password grant)."""
        return self._api.auth_token(
            grant_type="password",
            token_request=TokenRequest(email=email, password=password),
        )

    def sign_up(self, email: str, password: str, data: Optional[Dict[str, Any]] = None):
        """Register a new user (`POST /auth/v1/signup`)."""
        return self._api.auth_sign_up(
            sign_up_request=SignUpRequest(email=email, password=password, data=data),
        )


class Client:
    """Convenience entry point over the generated Grobase client.

    Example::

        from grobase.client import Client

        baas = Client("http://127.0.0.1:8002", api_key="anon-or-service-key")
        session = baas.auth.sign_in("user@example.com", "secret")
        rows = baas.from_("todos").select("*", limit=10)
    """

    def __init__(self, base_url: str, api_key: str) -> None:
        config = Configuration(host=base_url.rstrip("/"))
        config.api_key["apiKey"] = api_key
        self._api_client = ApiClient(configuration=config)
        self.auth = AuthClient(AuthApi(self._api_client))
        self._rest = RestApi(self._api_client)

    def from_(self, table: str) -> QueryBuilder:
        """Open a PostgREST-style builder bound to ``table``."""
        return QueryBuilder(self._rest, table)

    @property
    def api_client(self) -> ApiClient:
        """The underlying generated ``ApiClient`` (for advanced/direct use)."""
        return self._api_client
