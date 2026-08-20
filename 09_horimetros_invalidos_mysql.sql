-- 09_horimetros_invalidos.sql — VARIANTE MySQL 8 [NACIONAL r2]
WITH ultimo AS (
    SELECT i.*,
           ROW_NUMBER() OVER (PARTITION BY i.armac_code
                              ORDER BY i.event_datetime DESC) AS rn
    FROM total_integration.hourmeter_invalid i
    WHERE i.armac_code IS NOT NULL AND i.armac_code <> ''
)
SELECT
    UPPER(TRIM(armac_code))  AS n_armac,
    event_datetime           AS comunicacao_rastreador_em,
    hourmeter                AS horimetro_rastreador,
    source                   AS fonte_rastreador,
    error_code               AS motivo_rastreador
FROM ultimo WHERE rn = 1;
