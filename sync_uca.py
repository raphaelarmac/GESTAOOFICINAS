"""
sync_uca.py — lê o MySQL da ARMAC (UCA/fastfield) e envia via POST
para o webhook público do app.

Secrets:
  ARMAC_DB_HOST, ARMAC_DB_PORT, ARMAC_DB_USER, ARMAC_DB_PASSWORD
  UCA_DB_NAME        (default: fastfield)
  APP_BASE_URL       (ex: https://SEUAPP.lovable.app)
  SYNC_WEBHOOK_SECRET
"""
from __future__ import annotations
import json, os, sys
from datetime import date, datetime, timezone
from typing import Any
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError
import pymysql

DB_HOST = os.environ.get("ARMAC_DB_HOST") or ""
DB_PORT = int(os.environ.get("ARMAC_DB_PORT", "3306"))
DB_USER = os.environ.get("ARMAC_DB_USER") or ""
DB_PASSWORD = os.environ.get("ARMAC_DB_PASSWORD") or ""
DB_NAME = os.environ.get("UCA_DB_NAME", "fastfield")
APP_BASE_URL = (os.environ.get("APP_BASE_URL") or "").rstrip("/")
WEBHOOK_SECRET = os.environ.get("SYNC_WEBHOOK_SECRET") or ""

if not (DB_HOST and DB_USER and DB_PASSWORD):
    sys.exit("ERRO: ARMAC_DB_HOST/USER/PASSWORD não definidos")
if not WEBHOOK_SECRET or not APP_BASE_URL:
    sys.exit("ERRO: APP_BASE_URL / SYNC_WEBHOOK_SECRET não definidos")

UCA_QUERY = """
    SELECT
        UPPER(TRIM(n_armac))   AS n_armac,
        tipo_relatorio         AS tipo_relatorio,
        tipo_equipamento       AS equipamento,
        UPPER(TRIM(marca))     AS marca,
        UPPER(TRIM(modelo))    AS modelo,
        cliente                AS cliente,
        situacao               AS situacao,
        created_at_form        AS data_entrada,
        horimetro              AS horimetro,
        filial                 AS filial
    FROM fastfield.relatorio_entrada_saida_uca
    WHERE n_armac IS NOT NULL
      AND created_at_form IS NOT NULL
    ORDER BY created_at_form DESC
    LIMIT 50000
"""

def now_utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def jsonable(v: Any) -> Any:
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    if isinstance(v, datetime):
        return (v if v.tzinfo else v.replace(tzinfo=timezone.utc)).isoformat()
    if isinstance(v, date):
        return datetime(v.year, v.month, v.day, tzinfo=timezone.utc).isoformat()
    return str(v)

def fetch_mysql(query: str) -> list[dict]:
    conn = pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, connect_timeout=20, read_timeout=120,
        cursorclass=pymysql.cursors.DictCursor, charset="utf8mb4",
    )
    try:
        with conn.cursor() as cur:
            cur.execute(query)
            return list(cur.fetchall())
    finally:
        conn.close()

def post_json(path: str, body: dict) -> dict:
    req = urlrequest.Request(
        f"{APP_BASE_URL}{path}",
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Content-Type": "application/json",
            "x-webhook-secret": WEBHOOK_SECRET,
            "User-Agent": "sync_uca/1.0",
        },
    )
    try:
        with urlrequest.urlopen(req, timeout=180) as resp:
            txt = resp.read().decode("utf-8", errors="replace")
            try:
                return json.loads(txt)
            except json.JSONDecodeError:
                return {"ok": False, "raw": txt[:500]}
    except HTTPError as e:
        raise RuntimeError(f"HTTP {e.code}: {(e.read().decode('utf-8','replace') if e.fp else '')[:500]}")
    except URLError as e:
        raise RuntimeError(f"Falha de rede: {e}")

def main() -> int:
    started_at = now_utc_iso()
    try:
        registros = fetch_mysql(UCA_QUERY)
        eventos = [
            {
                "n_armac": jsonable(r.get("n_armac")),
                "tipo_relatorio": jsonable(r.get("tipo_relatorio")),
                "ts": jsonable(r.get("data_entrada")),
                "filial": jsonable(r.get("filial")),
                "cliente": jsonable(r.get("cliente")),
                "horimetro": jsonable(r.get("horimetro")),
            }
            for r in registros
        ]

        # rows = quem esta na filial agora: ultimo registro do ativo e' "Entrada".
        ultimo: dict[str, dict] = {}
        for r in registros:  # ja vem ordenado do mais novo para o mais antigo
            codigo = (r.get("n_armac") or "").strip()
            if codigo and codigo not in ultimo:
                ultimo[codigo] = r
        rows = [
            {k: jsonable(v) for k, v in r.items() if k != "tipo_relatorio"}
            for r in ultimo.values()
            if str(r.get("tipo_relatorio") or "").strip().lower().startswith("entrada")
        ]

        payload = {"started_at": started_at, "rows": rows, "eventos": eventos}

        result = post_json("/api/public/hooks/sync-ativos-bh", payload)
        
        if not result.get("ok"):
            raise RuntimeError(f"app respondeu sem ok: {result}")
        print(f"[UCA] ok · {len(rows)} na filial / {len(eventos)} eventos · {result.get('message') or ''}", flush=True)
        return 0
    except Exception as exc:
        print(f"[UCA] erro · {exc}", file=sys.stderr, flush=True)
        try:
            post_json("/api/public/hooks/sync-ativos-bh", {"started_at": started_at, "error": str(exc)})
        except Exception:
            pass
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
