# Queries do app — reescritas direto do SAP + otimizadas

Reescrita das 15 queries da Central de Atualização com dois objetivos:
**(1)** eliminar as views intermediárias e ler direto das tabelas nativas do SAP,
**(2)** performance.

Dialeto: **PostgreSQL** (o mesmo das queries originais — `ILIKE`, `::text`,
`LATERAL`, `"/scwm/aqua"`).

---

## Ordem de execução

| Passo | Arquivo | Para quê |
|---|---|---|
| 1 | `00_preflight_tabelas.sql` | Confere se as tabelas SAP existem na réplica. **Rode antes de tudo.** |
| 2 | `00b_extrair_ddl_views_atuais.sql` | Extrai a DDL das views que estamos removendo, para validar os campos marcados com TODO. |
| 3 | `99_indices_recomendados.sql` | Sem estes índices, metade do ganho não aparece. |
| 4 | Arquivos `01`–`15` | As queries. |

---

## O que mudou em cada query

| # | Arquivo | View removida | Mudança principal |
|---|---|---|---|
| 1 | `01_ordens_servico_sap.sql` | `pm_ordem_manutencao_cabecalho_v2` | AUFK+AFIH+CRHD+JEST. CRHD filtrada antes do join. |
| 2 | `02_os_operacoes.sql` | — (já nativa) | CRHD pré-filtrada; CTE `dados_planejamento` eliminada (AFKO é 1:1). |
| 3 | `03_equipamentos_sap.sql` | `armac.fi_ativos` (HANA) | EQUI+EQKT+EQUZ+ILOA. **3 campos com TODO.** |
| 4 | `04_os_suprimentos.sql` | `pm_ordem_manutencao_cabecalho_v2` | `LPAD(...,12,'0')` removido dos joins — AUFNR já vem padronizado do SAP. |
| 5 | `05_suprimentos_compras.sql` | — | **Unifica as queries 5 e 11** (eram idênticas). Recorte de data movido para o início. |
| 6 | `06_uca_patio.sql` | — (fastfield) | `MAX()` + self-join → `DISTINCT ON`. |
| 7 | `07_uca_historico.sql` | — (fastfield) | `EXISTS` correlacionado com `UPPER(TRIM())` → semi-join por CTE. |
| 8 | `08_horimetros.sql` | — (telemetria) | `MAX()` + self-join → `DISTINCT ON`. |
| 9 | `09_horimetros_invalidos.sql` | — (telemetria) | idem. |
| 10 | `10_reservas_separacao.sql` | `pm_ordem_manutencao_cabecalho_v2` | `SELECT DISTINCT` sobre ~65 colunas eliminado; EWM filtrada na origem. **6 campos com TODO.** |
| 11 | *(fundida na 05)* | — | O script `sync_compras_rcpc.py` pode parar de rodar. |
| 12 | `12_aprovacao_pedidos.sql` | `bi_bs_fluxo_aprov` | **Não reescrita.** Versão otimizada + esqueleto nativo para validar. |
| 13 | `13_pagamento_pedidos.sql` | — | **EKPO removida da query** (só servia para o join, o resultado não usa item). |
| 14 | `14_migo_recebimentos.sql` | — (app interno) | Limpeza; `''` → `NULL` na requisição. |
| 15 | `15_sap_pecas_historico.sql` | — | `LTRIM(TRIM())` removido dos 5 joins. |

---

## Bugs encontrados no caminho

Cada um está comentado dentro do arquivo correspondente.

**1. `NULL <> 'X'` não é `TRUE` (query 10) — muda contagem de linhas**

```sql
WHERE sgtxt <> 'Item não estocável'   -- descarta também as linhas com sgtxt NULL
  AND xloek <> 'X'                    -- descarta também as linhas com xloek NULL
```
Reservas ativas com `XLOEK` nulo estavam sumindo do relatório. Corrigido para
`IS DISTINCT FROM`. **Rode o comparativo de contagem no rodapé do arquivo 10
antes de subir** — se a intenção era mesmo excluir os NULLs, é só reverter.

**2. `ativo` com e sem zeros à esquerda dependendo da query**

A query 2 usava `AFIH.EQUNR` cru (`000000000012345`) e a 15 usava
`LTRIM(TRIM(EQUNR),'0')` (`12345`). As duas gravam `ativo` em tabelas que o app
cruza entre si. Padronizei **tudo sem zeros à esquerda**, alinhado com
`equipamentos_hana.ativo` (que vem de `numero_armac`). Confira se nada no app
depende do formato antigo.

**3. Desempate não-determinístico (queries 1 e 4)**

`ROW_NUMBER() OVER (PARTITION BY ... ORDER BY data_criacao DESC)` sem critério
de desempate: duas OS criadas no mesmo dia trocavam de lugar entre execuções, e
o "último" oscilava. Adicionado `aufnr DESC`.

**4. `PARTITION BY CASE` sem `ELSE` (query 4)**

Ordens que não caíam em PRP/OFI iam todas para a partição `NULL` e competiam
entre si pelo `rn = 1`.

**5. `MAX()` de texto como "última ordem" (query 15)**

`MAX(LTRIM(TRIM(AUFNR),'0'))` compara string: `'9998'` > `'10001'`. A
`ultima_ordem` não era a mais recente. Agora vem por `DISTINCT ON` da
`ultima_data`.

**6. 5 joins que duplicavam linha (query 10)**

`LIPS`, `CSKS`, `CEPCT`, `ANLH` e `ADRP` têm chave composta que a query ignorava
(período de validade, empresa, idioma). Era isso que o `SELECT DISTINCT` estava
mascarando — e ele custava um sort de ~65 colunas em disco. Cada join virou
`DISTINCT ON` na origem.

**7. `J.INACT = ''` (query 2)**

Se `INACT` vier `NULL` na réplica, o status era descartado em silêncio.
Trocado por `COALESCE(inact,'') <> 'X'`.

**8. Classificação Oficina/Preparação inconsistente entre queries 1 e 2**

A query 1 aceitava `tipo_atividade ILIKE '%prep%'` (texto) além de
`cod_tipo_atividade = 'PRP'`; a query 2 só olhava `ILART`. Ou seja, uma OS podia
entrar em `sap_os_records` e não em `sap_os_operacoes`. Mantive os dois
comportamentos como estavam para não mudar resultado, mas **vale decidir um só.**

---

## Sobre o `%%` que estava em todas as queries

As queries originais tinham `LIKE '%%BHZ%%'` porque o Python usava
`%`-formatting e precisava escapar. Nas reescritas isso virou:

```sql
strpos(c.arbpl, 'BHZ') > 0
```

Mesmo resultado, e **não sobrou nenhum `%` literal em nenhum arquivo** — o que
elimina de vez a classe de bug "esqueci de duplicar o `%%` ao mover a query".
Os únicos `%` que restam são placeholders nomeados do psycopg (`%(ini)s`,
`%(fim)s`).

---

## Campos marcados com TODO

São campos das views que **não têm equivalente único no SAP** — provavelmente
enriquecimentos feitos na própria view. Estão saindo `NULL` com um comentário
`-- TODO(n)`. Rode `00b_extrair_ddl_views_atuais.sql` e me mande o resultado
que eu fecho o mapeamento.

### `armac.fi_ativos` → EQUI (arquivo 03)

| Campo da view | Origem SAP proposta | Confiança |
|---|---|---|
| `numero_armac` | `EQUI.EQUNR` | alta |
| `descricao` | `EQKT.EQKTX` (SPRAS P) | alta |
| `chassi` | `EQUI.SERNR` → fallback `EQUI.SERGE` | média |
| `marca` | `EQUI.HERST` | alta |
| `modelo` | `EQUI.TYPBZ` | alta |
| `ano_fabricacao` | `EQUI.BAUJJ` | alta |
| `local_instalacao` | `ILOA.TPLNR` via `EQUZ` vigente | alta |
| `status_ativo` | ausência do status `I0076` (DLFL) | média |
| **`bu`** | **TODO(1)** — proposto `ILOA.SWERK` | baixa |
| **`tipo`** | **TODO(2)** — `EQUI.EQART` ou `EQUI.EQTYP` | baixa |
| **`grupo`** | **TODO(3)** — proposto `EQUI.GROES` | baixa |

### `pm_ordem_manutencao_cabecalho_v2` → AUFK/AFIH (arquivos 01, 04, 10)

Mapeados com confiança alta: `n_ordem`←AUFK.AUFNR, `n_equipamento`←AFIH.EQUNR,
`cod_tipo_ordem`←AUFK.AUART, `texto_breve`←AUFK.KTEXT,
`cod_tipo_atividade`←AFIH.ILART, `tipo_atividade`←T353I_T.ILATX,
`cod_prioridade`←AUFK.PRIOK, `prioridade`←T356_T.PRIOKX,
`cod_centro_trabalho`←CRHD.ARBPL (via AFIH.GEWRK), `local_instalacao`←AFIH.TPLNR,
`cod_grupo_plan`←AFIH.INGPR, `grupo_plan`←T024I.INNAM, `n_nota`←AFIH.QMNUM,
`n_plano_manutencao`←AFIH.WARPL, `n_item_manutencao`←AFIH.WAPOS,
`status_usuario`←JEST+TJ30T, `marcado_eliminacao`←AUFK.LOEKZ,
`dt_inicio_base`/`dt_fim_base`←AFKO.GSTRP/GLTRP,
`data_criacao`←AUFK.ERDAT, `data_liberada`←AUFK.IDAT1,
`data_encerrada_tecnicamente`←AUFK.IDAT2, `data_encerrada_comercialmente`←AUFK.IDAT3.

As flags `aberta` / `liberada` / `encerrada_*` passaram a ser derivadas de
IDAT1/IDAT2/IDAT3 (é mais barato e mais estável que ler JEST).

Sem equivalente:

| Campo | TODO | Comentário |
|---|---|---|
| `cod_responsavel`, `responsavel` | TODO(1) | Não é campo padrão de AUFK/AFIH. Pode ser um Z ou o responsável do centro de trabalho. |
| `email_ultimo_modificador` | TODO(2) | Enriquecimento — não existe no SAP. |
| `hora_ultima_modificacao` | TODO(3) | AUFK só guarda AEDAT (data). A hora está em CDHDR. |
| `n_solicitacao_manutencao`, `n_ultima_ordem` | TODO(4) | Precisa da regra de negócio. |
| `check_pipefy` | TODO(5) | Campo do app, não do SAP. |
| `dt_venc_final` | TODO(6) | Data calculada — precisa da fórmula. |

Os `CASE WHEN campo::text = '0000-00-00' THEN NULL` sumiram: aquilo era resquício
de data zerada estilo MySQL. Se a réplica trouxer `'00000000'` como texto em vez
de NULL, me avise que eu reponho o tratamento.

---

## Como validar antes de subir

Para cada query, rode as duas versões contra a mesma base e compare:

```sql
-- 1. contagem
SELECT count(*) FROM (<query antiga>) a;
SELECT count(*) FROM (<query nova>)   b;

-- 2. diferença em ambas as direções
SELECT * FROM (<query nova>)   EXCEPT ALL SELECT * FROM (<query antiga>);
SELECT * FROM (<query antiga>) EXCEPT ALL SELECT * FROM (<query nova>);

-- 3. tempo
EXPLAIN (ANALYZE, BUFFERS) <query>;
```

Diferenças **esperadas** (todas documentadas acima): query 10 com mais linhas
(bug 1), `ativo` sem zeros à esquerda (bug 2), query 13 com pedidos sem item
aparecendo como "Não Lançado", e queries 6/8/9 com menos linhas se havia
timestamps empatados.

---

## Ordem sugerida de rollout

1. **`13_pagamento_pedidos.sql`** — maior ganho, menor risco (remove EKPO).
2. **`15_sap_pecas_historico.sql`** — segundo maior ganho, resultado idêntico
   exceto pela correção da `ultima_ordem`.
3. **`06`–`09`** — trocas mecânicas, resultado idêntico.
4. **`05`** (e desligar `sync_compras_rcpc.py`).
5. **`02`, `04`, `14`**.
6. **`01`, `03`, `10`** — são as que mudam a fonte de dados. Rodar em paralelo
   com as antigas por alguns dias antes de cortar.
7. **`12`** — só depois de olhar a DDL da view.
