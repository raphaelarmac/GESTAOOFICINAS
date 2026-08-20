-- =============================================================================
-- 03_equipamentos_sap.sql
-- Substitui : sync_patio_total.py -> EQUIPAMENTOS_QUERY
-- Destino   : public.equipamentos_hana
-- Mudança   : lê direto de EQUI/EQKT/EQUZ/ILOA/JEST em vez da view HANA
--             armac.fi_ativos
--
-- >>> ATENÇÃO: LEIA ANTES DE SUBSTITUIR <<<
-- armac.fi_ativos é uma view de negócio da ARMAC. O mapeamento abaixo usa o
-- padrão SAP PM/EAM, mas 3 campos NÃO têm equivalente único e estão marcados
-- com TODO. Rode 00b_extrair_ddl_views_atuais.sql, pegue o SELECT da view e
-- confirme esses 3 antes de trocar. Os outros 8 campos são mapeamento direto.
--
-- Ganhos de performance:
--   * Um único passe por EQUI, com os textos resolvidos por DISTINCT ON
--     (EQKT tem uma linha por idioma; EQUZ tem uma linha por período de
--     validade — sem o DISTINCT ON o resultado duplica).
-- =============================================================================

WITH desc_equi AS (
    SELECT DISTINCT ON (k.equnr) k.equnr, k.eqktx
    FROM eqkt k
    WHERE lower(k.spras) IN ('p', 'pt')
    ORDER BY k.equnr, k.spras
),

local_atual AS (
    -- EQUZ guarda o histórico de instalação; queremos o registro vigente.
    SELECT DISTINCT ON (z.equnr)
        z.equnr,
        i.tplnr,
        i.swerk,
        i.kostl
    FROM equz z
    LEFT JOIN iloa i ON i.iloan = z.iloan
    ORDER BY z.equnr, z.datbi DESC
),

marcado_eliminacao AS (
    -- I0076 = DLFL (marcado para eliminação). É o filtro que mais se aproxima
    -- de status_ativo = 'Ativo' na view atual.
    SELECT DISTINCT j.objnr
    FROM jest j
    WHERE j.stat = 'I0076'
      AND COALESCE(j.inact, '') <> 'X'
)

SELECT
    -- TODO(1): `bu` na view = unidade de negócio. Candidato mais provável é o
    -- centro de planejamento (ILOA.SWERK). Se a ARMAC usa um campo Z ou a
    -- classificação (AUSP/CABN), troque aqui.
    la.swerk                                          AS tipo_holo,

    NULLIF(LTRIM(TRIM(e.equnr), '0'), '')             AS ativo,
    de.eqktx                                          AS descricao,

    -- Chassi: SERNR (nº de série) com fallback para SERGE (série do fabricante).
    NULLIF(TRIM(COALESCE(NULLIF(TRIM(e.sernr), ''), e.serge)), '') AS chassi,

    NULLIF(TRIM(e.herst), '')                         AS marca,
    NULLIF(TRIM(e.typbz), '')                         AS modelo,

    -- TODO(2): `tipo` na view. EQART = tipo de objeto técnico. Se a view usa
    -- EQTYP (categoria de equipamento), troque por e.eqtyp.
    NULLIF(TRIM(e.eqart), '')                         AS tipo_equipamento,

    -- TODO(3): `grupo` (porte/tonelagem). GROES é o campo livre de dimensões,
    -- que é onde a tonelagem costuma estar. Confirme na DDL da view.
    NULLIF(TRIM(e.groes), '')                         AS porte_tonelagem,

    NULLIF(TRIM(e.baujj), '')                         AS ano_fabricacao,
    'Ativo'::text                                     AS status_ativo,
    NULLIF(TRIM(la.tplnr), '')                        AS local_instalacao

FROM equi e
LEFT JOIN desc_equi  de ON de.equnr = e.equnr
LEFT JOIN local_atual la ON la.equnr = e.equnr
WHERE NOT EXISTS (SELECT 1 FROM marcado_eliminacao m WHERE m.objnr = e.objnr)
ORDER BY 2;
