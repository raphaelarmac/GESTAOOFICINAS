# NACIONAL r2 — Changelog (19/08/2026)

Pacote derivado do `queries_sync_pack_corrigido` (que já tinha o patch OBJTY r1
e as respostas dos TODOs). Objetivo do r2: **escopo nacional** — todas as
filiais e responsáveis, filial como COLUNA, nunca como WHERE — sem deixar
pesado. Leitura no datalake Postgres; entrega via webhook autenticado ao app.

## Arquivos alterados

| Arquivo | Mudança |
|---|---|
| `01_ordens_servico_sap.sql` | Reescrita. CT BHZ/BET removido; CRHD virou LEFT JOIN de dicionário; colunas novas `filial` (prefixo do ARBPL antes do `\|`) e `centro_trabalho`; joins de status com TRIM (padding da réplica) e SPRAS 'P'. |
| `02_os_operacoes.sql` | Reescrita. Idem 01; mantido o recorte de negócio `ILART IN ('PRP','OFI')`; coluna `filial` adicionada; TRIM no join da JEST; SPRAS 'P'. |
| `04_os_suprimentos.sql` | Patch. CT virou dicionário sem filtro; CRHD LEFT; coluna `filial` propagada por todas as CTEs até a saída. |
| `06_uca_patio.sql` | Reescrita. Filtro BH removido; último evento por ativo é GLOBAL (a máquina só está em um lugar); `filial` indica o pátio atual. |
| `07_uca_historico.sql` | Reescrita. CTE `ativos_bh` eliminada — histórico completo de todos os ativos, e a query ficou mais barata (uma varredura, zero join). |
| `10_reservas_separacao.sql` | Patch. TRIM nos joins de status (jsto/jest.objnr, tj30t.stsma). Não tinha filtro regional. |
| `99_indices_recomendados.sql` | Índices de EXPRESSÃO adicionados: `TRIM(objnr)` em jest/jsto e `TRIM(stsma)` em tj30t — sem eles os joins com TRIM viram seq scan. |

## Arquivos NÃO alterados (e por quê)

- `03, 08, 09, 12, 13, 14, 15`: já eram nacionais (sem filtro de filial).
- `05` e `13`: os filtros de **grupo de compras** (`ekgrp 201/220/251`) e
  compradores nomeados NÃO são filtro de filial — são recorte de negócio de
  suprimentos. Ficaram como estavam. **Decisão pendente sua**: se a visão
  nacional de compras precisar de mais grupos, a lista está no topo de cada
  query; removê-la por completo multiplica o volume de EBAN/EKKO — se for esse
  o caso, obrigatório encurtar a janela `%(ini)s` (ex.: 30 dias) nas execuções
  recorrentes.

## Estratégia de performance nacional (por que não fica pesado)

1. **O peso não está no Brasil, está no histórico.** As queries 01/02/04 já
   limitam o resultado a "última OS por ativo × tipo" — nacionalmente o output
   cresce com a FROTA (linear), não com as ~466 mil ordens desde 2024. O
   status (JEST) continua sendo buscado só para as campeãs.
2. **Índices viram pré-requisito.** Com o filtro de filial removido, a
   seletividade vem de `ix_aufk_erdat` + chaves de join. Rodar o `99` ANTES da
   primeira carga nacional, incluindo os novos índices de expressão do TRIM.
3. **Fastfield (06/07)**: 06 continua DISTINCT ON com índice; 07 ficou mais
   barata que a versão BH (perdeu um join).
4. **Cargas incrementais**: manter `%(ini)s` curto nas execuções recorrentes
   (05/12/13/15). As queries de fotografia (01/02/04/06) são full por natureza
   — são snapshot do estado atual, não histórico.
5. **Destino**: entrega em lotes via webhook autenticado; usuários de banco
   do pipeline são somente leitura nas origens.

## Validação específica do r2 (além do checklist do README)

```sql
-- (a) distribuição por filial: sanity check do split_part
SELECT filial, COUNT(*) FROM (<query 01>) x GROUP BY 1 ORDER BY 2 DESC;
-- esperado: BHZ/BET aparecem com os mesmos números de antes; filiais novas
-- aparecem; NULL = ordens sem centro (antes elas simplesmente não existiam).

-- (b) regressão do recorte antigo: o resultado BH do r2 == resultado do r1
SELECT * FROM (<query 01 r2>) x WHERE filial IN ('BHZ','BET')
EXCEPT ALL
SELECT ativo, filial, ... FROM (<query 01 r1>);
-- (atenção à ordem/lista de colunas: r2 tem centro_trabalho a mais)

-- (c) status de usuário: agora deve vir preenchido
SELECT COUNT(*) FILTER (WHERE status_usuario IS NOT NULL)::float / COUNT(*)
FROM (<query 01>) x;
-- se der 0, rode os checks de SPRAS/TRIM do preflight.
```

## Avisos herdados que continuam valendo

- Bug 8 do README (classificação Oficina/Preparação divergente entre 01 e 02)
  segue existindo — decidir critério único antes do corte.
- Testar a Conciliação UCA do app após o rollout (formato do `ativo` sem zeros
  + agora ativos de todas as filiais entrando no espelho).
- `armac.fi_ativos` (03): TODOs 1–3 ainda dependem do 00b parte B no HANA.


## r2.1 (19/08/2026) — compras sem recorte de comprador

- `05_suprimentos_compras.sql`: filtros `ekgrp IN (201,220,251)` / compradores
  nomeados REMOVIDOS. Coluna nova `grupo_compras`. A janela `%(ini)s/%(fim)s`
  é agora a única seletividade — **carga inicial fatiada por período** (ano a
  ano), recorrente com janela curta (ini=30).
- `13_pagamento_pedidos.sql`: idem; colunas novas `grupo_compras` e
  `criado_por_sap`. `ix_ekko_bedat` + `ix_ekbe_ebeln_fatura` (já no 99) seguram
  o volume.
- Racional: o pipeline entrega TUDO; o recorte por grupo/comprador vira regra
  do APP (visível, auditável, mudável sem redeploy do pipeline). De quebra,
  some a lista de nomes de funcionários hardcoded do repositório — um item a
  menos de exposição se o repo vazar.
