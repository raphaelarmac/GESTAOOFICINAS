# GESTAOOFICINAS — Central de Atualizações

Pipeline de sincronização: executa queries versionadas em `sql/` contra as
fontes de dados e entrega os resultados ao aplicativo via webhook autenticado.

## Estrutura
- `sql/` — queries (PostgreSQL) numeradas 00–15 + 99 (índices). `00` é o
  preflight: rode antes de tudo. `sql/mysql/` tem variantes para fontes MySQL.
- `sync/run_sync.py` — runner genérico. `python sync/run_sync.py --list`
  mostra os jobs. Toda configuração vem de variáveis de ambiente/secrets.
- `.github/workflows/sync.yml` — agendamento (grupo operação 4x/dia,
  grupo pesado 1x/dia) e execução manual por job.

## Execução manual
Actions → "Central de Atualizações — Sync" → Run workflow → escolher o job.

Documentação técnica das queries: `README_QUERIES.md` e `NACIONAL_r2_CHANGES.md`.
