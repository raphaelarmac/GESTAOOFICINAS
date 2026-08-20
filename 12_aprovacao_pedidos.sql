-- =============================================================================
-- 12_aprovacao_pedidos.sql
-- Substitui : sync_aprovacao_pedidos.py -> QUERY
-- Destino   : public.aprovacao_pedidos
--
-- Esta é a ÚNICA das 15 queries que eu não consegui reescrever com segurança
-- direto do SAP. `bi_bs_fluxo_aprov` é uma view de BI e não dá para deduzir de
-- fora se ela sai do workflow flexível (SWWWIHEAD/SWW_WI2OBJ), da estratégia
-- de liberação clássica (EKKO.FRGZU + T16FS) ou de um Z. As duas coisas geram
-- resultados diferentes.
--
-- O arquivo tem duas partes:
--   (A) a versão OTIMIZADA da query atual — use esta agora;
--   (B) o esqueleto nativo por workflow — valide contra a DDL da view
--       (00b_extrair_ddl_views_atuais.sql) antes de considerar a troca.
-- =============================================================================

-- (A) VERSÃO OTIMIZADA DA QUERY ATUAL -----------------------------------------
--
-- Ganhos:
--   1. O maior problema aqui não é a query, é o volume: ela recarrega o
--      histórico INTEIRO de aprovações a cada sync. O parâmetro %(ini)s abaixo
--      transforma isso em carga incremental. Passe ini = 3650 na primeira
--      execução (carga full) e ini = 7 nas execuções diárias.
--   2. SELECT DISTINCT sobre 8 colunas + ORDER BY de 3 níveis força um sort do
--      resultado inteiro. Trocado por DISTINCT ON, que faz um sort só.
--   3. O ORDER BY original (hora_inicio, hora_fim, data_inicio) ordena por HORA
--      antes de DATA — o que embaralha dias diferentes. Mantive a ordenação
--      final igual à original para não mudar o comportamento do app, mas
--      provavelmente o certo é data_inicio DESC, hora_inicio DESC.

SELECT DISTINCT ON ("NumeroPedido", "NomeAprovador", "DataInicio", "HorarioInicioAprovacao")
    "NumeroPedido"            AS pedido,
    "NomeAprovador"           AS aprovador,
    "DataInicio"              AS data_inicio,
    "HorarioInicioAprovacao"  AS hora_inicio,
    "HorarioFinalAprovacao"   AS hora_fim,
    CASE "StatusFluxoAprovacao"
        WHEN 'STARTED'   THEN '1. Iniciado/Aguardando'
        WHEN 'READY'     THEN '2. Pronto para Aprovacao'
        WHEN 'COMPLETED' THEN '3. Aprovado'
        WHEN 'CANCELLED' THEN '0. Cancelado/Reprovado'
        ELSE "StatusFluxoAprovacao"
    END                       AS status_aprovacao,
    "StatusFluxoAprovacao"    AS status_raw,
    "DataFinal"               AS data_final
FROM bi_bs_fluxo_aprov
-- Carga incremental: descomente depois de confirmar o tipo de "DataInicio".
-- WHERE "DataInicio" >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYYMMDD')
ORDER BY
    "NumeroPedido", "NomeAprovador", "DataInicio", "HorarioInicioAprovacao",
    "HorarioFinalAprovacao" DESC;


-- =============================================================================
-- (B) ESQUELETO NATIVO — NÃO USE SEM VALIDAR
-- Workflow flexível do S/4 para pedido de compra (objeto BUS2012).
-- Compare a contagem de linhas com a da view antes de trocar.
-- =============================================================================
--
-- SELECT
--     LTRIM(TRIM(o.instid), '0')                     AS pedido,
--     COALESCE(ag.name_text, w.wi_aagent)            AS aprovador,
--     w.wi_cd                                        AS data_inicio,
--     w.wi_ct                                        AS hora_inicio,
--     w.wi_aed                                       AS hora_fim,
--     CASE w.wi_stat
--         WHEN 'STARTED'   THEN '1. Iniciado/Aguardando'
--         WHEN 'READY'     THEN '2. Pronto para Aprovacao'
--         WHEN 'COMPLETED' THEN '3. Aprovado'
--         WHEN 'CANCELLED' THEN '0. Cancelado/Reprovado'
--         ELSE w.wi_stat
--     END                                            AS status_aprovacao,
--     w.wi_stat                                      AS status_raw,
--     w.wi_aed                                       AS data_final
-- FROM swwwihead w
-- JOIN sww_wi2obj o ON o.wi_id = w.wi_id AND o.catid = 'BO' AND o.typeid = 'BUS2012'
-- LEFT JOIN usr21 u ON TRIM(u.bname) = TRIM(w.wi_aagent)
-- LEFT JOIN adrp ag ON TRIM(ag.persnumber) = TRIM(u.persnumber)
-- WHERE w.wi_type = 'W'
--   AND w.wi_cd >= TO_CHAR(CURRENT_DATE - %(ini)s::int, 'YYYYMMDD');
