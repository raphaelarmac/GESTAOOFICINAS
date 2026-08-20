-- =============================================================================
-- 09_horimetros_invalidos.sql
-- Substitui : sync_patio_total.py -> HORIMETRO_INVALIDO_QUERY
-- Destino   : public.ativo_horimetros / public.horimetro_sync_status
-- Fonte     : total_integration (telemetria, não é SAP) - mantida
--
-- Ganho de performance: self-join com MAX() -> DISTINCT ON.
-- =============================================================================

SELECT DISTINCT ON (i.armac_code)
    UPPER(TRIM(i.armac_code))  AS n_armac,
    i.event_datetime           AS comunicacao_rastreador_em,
    i.hourmeter                AS horimetro_rastreador,
    i.source                   AS fonte_rastreador,
    i.error_code               AS motivo_rastreador
FROM total_integration.hourmeter_invalid i
WHERE i.armac_code IS NOT NULL
  AND i.armac_code <> ''
ORDER BY i.armac_code, i.event_datetime DESC;
