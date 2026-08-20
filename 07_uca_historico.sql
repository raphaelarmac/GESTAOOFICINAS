-- =============================================================================
-- 07_uca_historico.sql                                       [NACIONAL r2]
-- Substitui : sync_patio_total.py -> UCA_HISTORICO_QUERY
-- Destino   : public.ativo_uca_eventos
-- Fonte     : fastfield (não é SAP) - mantida
--
-- MUDANÇAS r2 (escopo nacional, 19/08/2026):
--   * A CTE `ativos_bh` (semi-join que restringia aos ativos que já passaram
--     por BH) foi REMOVIDA por inteiro: nacionalmente queremos o histórico
--     de todos os ativos, de todas as filiais. De quebra a query ficou mais
--     barata — uma varredura só, sem join.
--   * A filial de cada evento já era coluna e continua sendo.
-- =============================================================================

SELECT
    UPPER(TRIM(r.n_armac))  AS n_armac,
    r.tipo_relatorio        AS tipo_relatorio,
    r.created_at_form       AS ts,
    r.filial                AS filial,
    r.cliente               AS cliente,
    r.situacao              AS situacao,
    r.horimetro             AS horimetro,
    r.tipo_equipamento      AS descricao
FROM fastfield.relatorio_entrada_saida_uca r
WHERE r.n_armac IS NOT NULL
  AND r.n_armac <> ''
  AND r.created_at_form IS NOT NULL
  AND r.tipo_relatorio IN ('Entrada', 'Saída', 'Saida');
