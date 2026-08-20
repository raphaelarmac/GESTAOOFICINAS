#!/usr/bin/env python3
"""
run_sync.py — runner genérico da Central de Atualizações (GESTAOOFICINAS)

Executa a query SQL de um "job" na origem correta e entrega o resultado ao
app via webhook autenticado (mesmo padrão dos sync_*.py originais).

Uso:
    python run_sync.py --job pagamento_pedidos
    python run_sync.py --job suprimentos_compras --ini 30 --fim 0
    python run_sync.py --list

Secrets/env necessários (mesmos nomes já configurados no repo):
    Datalake Postgres : HANA_DB_HOST/PORT/USER/PASSWORD/NAME
    MySQL ARMAC       : ARMAC_DB_HOST/PORT/USER/PASSWORD (+ UCA_DB_NAME p/ UCA)
    MySQL MIGO        : MIGO_DB_HOST/PORT/USER/PASSWORD/NAME
    Telemetria        : TELEMETRIA_DB_HOST/PORT/USER/PASSWORD/NAME
                        (engine auto: porta 5432 -> Postgres, senão MySQL;
                         force com TELEMETRIA_DB_ENGINE=pg|mysql)
    App               : APP_BASE_URL, SYNC_WEBHOOK_SECRET

Regras de segurança (não relaxar):
    * Nenhuma credencial hardcoded — só env/secrets.
    * Somente SELECT/WITH é aceito do arquivo SQL (guarda abaixo).
    * Usuários de banco devem ser SOMENTE LEITURA nas origens.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

RAIZ = Path(__file__).resolve().parent
SQL_DIR = RAIZ  # estrutura flat: SQL na raiz do repo
LOTE_WEBHOOK = 2000          # linhas por POST
TENTATIVAS_QUERY = 3         # retry p/ conflito de réplica (herdado do legado)

# ----------------------------------------------------------------------------
# REGISTRO DE JOBS
#   fonte : "pg" (datalake) | "mysql" (ARMAC)
#   hook  : caminho do webhook no app. Os marcados TODO_HOOK ainda precisam
#           ser criados no app (ver MIGRACAO_REPO.md) — o runner falha com
#           mensagem clara se o hook responder 404.
#   params: nomes aceitos via --ini/--fim (%(ini)s / %(fim)s no SQL)
# ----------------------------------------------------------------------------
JOBS: dict[str, dict[str, Any]] = {
    "ordens_servico":      {"sql": "01_ordens_servico_sap.sql",  "fonte": "pg",
                            "hook": "/api/public/hooks/sync-sap-os"},                # TODO_HOOK
    "os_operacoes":        {"sql": "02_os_operacoes.sql",        "fonte": "pg",
                            "hook": "/api/public/hooks/sync-sap-os-operacoes"},      # TODO_HOOK
    "equipamentos":        {"sql": "03_equipamentos_sap.sql",    "fonte": "pg",
                            "hook": "/api/public/hooks/sync-equipamentos"},          # TODO_HOOK
    "os_suprimentos":      {"sql": "04_os_suprimentos.sql",      "fonte": "pg",
                            "hook": "/api/public/hooks/sync-os-suprimentos"},        # TODO_HOOK
    "suprimentos_compras": {"sql": "05_suprimentos_compras.sql", "fonte": "pg",
                            "hook": "/api/public/hooks/sync-suprimentos-compras",    # TODO_HOOK
                            "params": ("ini", "fim"), "padrao": {"ini": 30, "fim": 0}},
    "uca_patio":           {"sql": "06_uca_patio_mysql.sql",     "fonte": "armac",
                            "db": os.environ.get("UCA_DB_NAME", "fastfield"),
                            "hook": "/api/public/hooks/sync-uca-patio"},             # TODO_HOOK (hoje: sync_uca.py)
    "uca_historico":       {"sql": "07_uca_historico.sql",       "fonte": "armac",
                            "db": os.environ.get("UCA_DB_NAME", "fastfield"),
                            "hook": "/api/public/hooks/sync-uca-historico"},         # TODO_HOOK (hoje: sync_uca.py)
    "horimetros":          {"sql": "08_horimetros_mysql.sql",    "fonte": "telemetria",
                            "hook": "/api/public/hooks/sync-horimetros"},            # TODO_HOOK
    "horimetros_invalidos":{"sql": "09_horimetros_invalidos_mysql.sql", "fonte": "telemetria",
                            "hook": "/api/public/hooks/sync-horimetros-invalidos"},  # TODO_HOOK
    "reservas_separacao":  {"sql": "10_reservas_separacao.sql",  "fonte": "pg",
                            "hook": "/api/public/hooks/sync-reservas-separacao"},    # TODO_HOOK
    "aprovacao_pedidos":   {"sql": "12_aprovacao_pedidos.sql",   "fonte": "pg",
                            "hook": "/api/public/hooks/sync-aprovacao-pedidos",      # TODO_HOOK
                            "params": ("ini",), "padrao": {"ini": 7}},
    "pagamento_pedidos":   {"sql": "13_pagamento_pedidos.sql",   "fonte": "pg",
                            "hook": "/api/public/hooks/sync-pagamento-pedidos",      # hook JÁ EXISTE no app
                            "params": ("ini",), "padrao": {"ini": 90}},
    "migo_recebimentos":   {"sql": "14_migo_recebimentos.sql",   "fonte": "migo",
                            "hook": "/api/public/hooks/sync-migo"},                  # hook do sync_migo.py — confirmar caminho
    "pecas_historico":     {"sql": "15_sap_pecas_historico.sql", "fonte": "pg",
                            "hook": "/api/public/hooks/sync-pecas-historico",        # TODO_HOOK
                            "params": ("ini", "fim"), "padrao": {"ini": 365, "fim": 0}},
}

# ----------------------------------------------------------------------------

def _env(nome: str, *alts: str, obrigatorio: bool = True) -> str:
    for n in (nome, *alts):
        v = os.environ.get(n)
        if v and v.strip():
            # .strip() blinda contra secrets colados com espaço/Enter no final
            # (causa do "could not translate host name" no primeiro run).
            return v.strip()
    if obrigatorio:
        sys.exit(f"ERRO: variável {nome} não definida")
    return ""


def _assert_somente_leitura(sql: str) -> None:
    corpo = re.sub(r"--[^\n]*", "", sql)               # remove comentários
    primeira = re.search(r"\b(\w+)\b", corpo, re.I)
    if not primeira or primeira.group(1).upper() not in ("SELECT", "WITH"):
        sys.exit("ERRO: o arquivo SQL não começa com SELECT/WITH — bloqueado.")
    proibidos = re.findall(
        r"\b(INSERT|UPDATE|DELETE|DROP|TRUNCATE|ALTER|GRANT|REVOKE|CREATE)\b",
        corpo, re.I)
    if proibidos:
        sys.exit(f"ERRO: comando não permitido no SQL: {sorted(set(p.upper() for p in proibidos))}")


def jsonable(v: Any) -> Any:
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    if isinstance(v, datetime):
        return (v if v.tzinfo else v.replace(tzinfo=timezone.utc)).isoformat()
    if isinstance(v, date):
        return v.isoformat()
    return str(v)


def _eh_conflito_replica(err: Exception) -> bool:
    t = str(err).lower()
    return "conflict with recovery" in t or "canceling statement due to conflict" in t


def buscar_pg(sql: str, params: dict | None) -> list[dict]:
    import psycopg2
    import psycopg2.extras
    ultimo: Exception | None = None
    for tentativa in range(1, TENTATIVAS_QUERY + 1):
        try:
            conn = psycopg2.connect(
                host=_env("HANA_DB_HOST", "SAP_DB_HOST"),
                port=int(_env("HANA_DB_PORT", "SAP_DB_PORT", obrigatorio=False) or 5432),
                user=_env("HANA_DB_USER", "SAP_DB_USER"),
                password=_env("HANA_DB_PASSWORD", "SAP_DB_PASSWORD"),
                dbname=_env("HANA_DB_NAME", "SAP_DB_NAME"),
                connect_timeout=30,
            )
            conn.autocommit = True
            try:
                with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                    cur.execute(sql, params or None)
                    return [dict(r) for r in cur.fetchall()]
            finally:
                conn.close()
        except Exception as e:                                   # noqa: BLE001
            ultimo = e
            if _eh_conflito_replica(e) and tentativa < TENTATIVAS_QUERY:
                espera = 30 * tentativa
                print(f"conflito de réplica; retry em {espera}s...", flush=True)
                time.sleep(espera)
            else:
                raise
    raise ultimo  # pragma: no cover


def buscar_mysql(sql: str, prefixo: str, db: str | None = None) -> list[dict]:
    import pymysql
    conn = pymysql.connect(
        host=_env(f"{prefixo}_HOST"),
        port=int(os.environ.get(f"{prefixo}_PORT") or "3306"),  # "or": secret ausente vira '' no Actions
        user=_env(f"{prefixo}_USER"),
        password=_env(f"{prefixo}_PASSWORD"),
        database=db or _env(f"{prefixo}_NAME"),
        connect_timeout=20, read_timeout=300,
        cursorclass=pymysql.cursors.DictCursor, charset="utf8mb4",
    )
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            return list(cur.fetchall())
    finally:
        conn.close()


def buscar_telemetria(sql: str) -> list[dict]:
    """TELEMETRIA_DB_* pode ser MySQL ou Postgres: decide por env ou porta."""
    engine = (os.environ.get("TELEMETRIA_DB_ENGINE") or "").lower()
    porta = os.environ.get("TELEMETRIA_DB_PORT", "")
    eh_pg = engine == "pg" or (not engine and porta == "5432")
    if not eh_pg:
        return buscar_mysql(sql, "TELEMETRIA_DB")
    import psycopg2
    import psycopg2.extras
    conn = psycopg2.connect(
        host=_env("TELEMETRIA_DB_HOST"),
        port=int(porta or 5432),
        user=_env("TELEMETRIA_DB_USER"),
        password=_env("TELEMETRIA_DB_PASSWORD"),
        dbname=_env("TELEMETRIA_DB_NAME"),
        connect_timeout=30,
    )
    conn.autocommit = True
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def postar(hook: str, body: dict) -> None:
    base = _env("APP_BASE_URL").rstrip("/")
    req = urlrequest.Request(
        f"{base}{hook}",
        data=json.dumps(body, default=str).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-webhook-secret": _env("SYNC_WEBHOOK_SECRET"),
            "User-Agent": "gestaooficinas-run-sync/2.0",
        },
    )
    try:
        with urlrequest.urlopen(req, timeout=300) as resp:
            print(f"  webhook {resp.status}: {resp.read()[:120].decode('utf-8', 'ignore')}", flush=True)
    except HTTPError as e:
        detalhe = e.read()[:400].decode("utf-8", "ignore") if e.fp else ""
        if e.code == 404:
            sys.exit(f"ERRO: hook {hook} não existe no app (TODO_HOOK — ver MIGRACAO_REPO.md). {detalhe}")
        raise RuntimeError(f"HTTP {e.code} em {hook}: {detalhe}") from e
    except URLError as e:
        raise RuntimeError(f"Falha de rede em {hook}: {e}") from e


def rodar(job_nome: str, ini: int | None, fim: int | None) -> int:
    job = JOBS[job_nome]
    sql_path = SQL_DIR / job["sql"]
    sql = sql_path.read_text(encoding="utf-8")
    _assert_somente_leitura(sql)

    params: dict[str, int] = {}
    for p in job.get("params", ()):  # aplica --ini/--fim ou o padrão do job
        valor = {"ini": ini, "fim": fim}.get(p)
        params[p] = valor if valor is not None else job["padrao"][p]

    inicio = datetime.now(timezone.utc).isoformat()
    print(f"[{job_nome}] fonte={job['fonte']} sql={job['sql']} params={params or '-'}", flush=True)

    if job["fonte"] == "pg":
        linhas = buscar_pg(sql, params or None)
    elif job["fonte"] == "armac":
        linhas = buscar_mysql(sql, "ARMAC_DB", job.get("db"))
    elif job["fonte"] == "migo":
        linhas = buscar_mysql(sql, "MIGO_DB")
    elif job["fonte"] == "telemetria":
        linhas = buscar_telemetria(sql)
    else:
        raise ValueError(f"fonte desconhecida: {job['fonte']}")

    print(f"[{job_nome}] query OK: {len(linhas)} linhas", flush=True)
    linhas = [{k: jsonable(v) for k, v in r.items()} for r in linhas]

    total_lotes = max(1, -(-len(linhas) // LOTE_WEBHOOK))
    for i in range(total_lotes):
        lote = linhas[i * LOTE_WEBHOOK:(i + 1) * LOTE_WEBHOOK]
        postar(job["hook"], {
            "job": job_nome,
            "batch": i + 1,
            "total_batches": total_lotes,
            "row_count": len(lote),
            "total_rows": len(linhas),
            "started_at": inicio,
            "sent_at": datetime.now(timezone.utc).isoformat(),
            "rows": lote,
        })
        print(f"  lote {i + 1}/{total_lotes} enviado ({len(lote)} linhas)", flush=True)

    print(f"[{job_nome}] concluído.", flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Runner da Central de Atualizações")
    ap.add_argument("--job", choices=sorted(JOBS), help="nome do job")
    ap.add_argument("--ini", type=int, help="janela: dias para trás (início)")
    ap.add_argument("--fim", type=int, help="janela: dias para trás (fim)")
    ap.add_argument("--list", action="store_true", help="lista os jobs e sai")
    args = ap.parse_args()

    if args.list or not args.job:
        for nome, j in sorted(JOBS.items()):
            print(f"{nome:22s} fonte={j['fonte']:5s} sql={j['sql']}")
        return 0
    return rodar(args.job, args.ini, args.fim)


if __name__ == "__main__":
    sys.exit(main())
