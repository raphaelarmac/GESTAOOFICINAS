-- 08_horimetros.sql — VARIANTE MySQL 8 [NACIONAL r2]
WITH ultimo AS (
    SELECT h.*,
           ROW_NUMBER() OVER (PARTITION BY h.armac_code
                              ORDER BY h.event_datetime DESC,
                                       h.updated_at DESC) AS rn
    FROM total_integration.hourmeter h
    WHERE h.armac_code IS NOT NULL AND h.armac_code <> ''
)
SELECT
    UPPER(TRIM(armac_code))                        AS n_armac,
    event_datetime                                 AS data_comunicacao,
    COALESCE(equipment_hourmeter, panel_hourmeter) AS horimetro_sistema,
    contract                                       AS contrato,
    updated_at                                     AS atualizado_em
FROM ultimo WHERE rn = 1;
