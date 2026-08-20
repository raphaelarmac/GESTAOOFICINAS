-- =============================================================================
-- 08_horimetros.sql
-- Substitui : sync_patio_total.py -> HORIMETRO_QUERY
-- Destino   : public.ativo_horimetros
-- Fonte     : total_integration (telemetria, não é SAP) - mantida
--
-- Ganho de performance: self-join com MAX() -> DISTINCT ON (uma leitura só).
-- Correção: empates de event_datetime deixam de duplicar a linha no destino.
-- =============================================================================

SELECT DISTINCT ON (h.armac_code)
    UPPER(TRIM(h.armac_code))                          AS n_armac,
    h.event_datetime                                   AS data_comunicacao,
    COALESCE(h.equipment_hourmeter, h.panel_hourmeter) AS horimetro_sistema,
    h.contract                                         AS contrato,
    h.updated_at                                       AS atualizado_em
FROM total_integration.hourmeter h
WHERE h.armac_code IS NOT NULL
  AND h.armac_code <> ''
ORDER BY h.armac_code, h.event_datetime DESC, h.updated_at DESC NULLS LAST;
