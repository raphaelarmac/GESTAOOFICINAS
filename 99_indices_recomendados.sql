-- =============================================================================
-- 99_indices_recomendados.sql
--
-- Reescrever a query só resolve metade. Sem estes índices, várias das queries
-- continuam fazendo seq scan nas tabelas grandes da réplica.
--
-- Rode com CONCURRENTLY em produção (fora de transação — não pode estar dentro
-- de BEGIN/COMMIT). Depois rode ANALYZE nas tabelas afetadas.
--
-- Confira o schema: se as tabelas SAP não estiverem em `public`, ajuste o
-- prefixo. Confira também se algum destes já existe (\d tabela no psql).
-- =============================================================================

-- ---------------------------------------------------------- ordens (01,02,04)
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aufk_erdat        ON aufk (erdat);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aufk_aufnr        ON aufk (aufnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afih_aufnr        ON afih (aufnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afih_gewrk        ON afih (gewrk);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afih_equnr        ON afih (equnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afko_aufnr        ON afko (aufnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afko_aufpl        ON afko (aufpl);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afvc_aufpl_aplzl  ON afvc (aufpl, aplzl);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_afvv_aufpl_aplzl  ON afvv (aufpl, aplzl);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_crhd_objty_objid  ON crhd (objty, objid);

-- status (01,02,10) — o filtro parcial mantém o índice pequeno
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_jest_objnr_ativo
    ON jest (objnr, stat) WHERE COALESCE(inact, '') <> 'X';
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_jsto_objnr         ON jsto (objnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_tj30t_stsma_estat  ON tj30t (stsma, estat, spras);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_tj02t_istat_spras  ON tj02t (istat, spras);

-- ------------------------------------------------------- equipamentos (03,15)
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_equi_objnr         ON equi (objnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_eqkt_equnr_spras   ON eqkt (equnr, spras);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_equz_equnr_datbi   ON equz (equnr, datbi DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_iloa_iloan         ON iloa (iloan);

-- --------------------------------------------------------- compras (04,05,13)
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_eban_badat         ON eban (badat);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_eban_banfn_bnfpo   ON eban (banfn, bnfpo);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ebkn_banfn_bnfpo   ON ebkn (banfn, bnfpo);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ebkn_aufnr         ON ebkn (aufnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekpo_banfn_bnfpo   ON ekpo (banfn, bnfpo);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekpo_ebeln_ebelp   ON ekpo (ebeln, ebelp);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekko_ebeln         ON ekko (ebeln);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekko_bedat         ON ekko (bedat);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekkn_ebeln_ebelp   ON ekkn (ebeln, ebelp);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_eket_ebeln_ebelp   ON eket (ebeln, ebelp, eindt);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_lfa1_lifnr         ON lfa1 (lifnr);

-- EKBE: usada em 05 (VGABE='1') e em 13 (VGABE='2')
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekbe_ebeln_ebelp_vgabe ON ekbe (ebeln, ebelp, vgabe);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_ekbe_ebeln_fatura
    ON ekbe (ebeln, budat) WHERE vgabe = '2';

-- ------------------------------------------------------- reservas (04,10,15)
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_resb_aufnr         ON resb (aufnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_resb_rsnum_rspos   ON resb (rsnum, rspos);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_resb_banfn_bnfpo   ON resb (banfn, bnfpo);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_resb_separacao
    ON resb (lgort, bwart) WHERE lgort IN ('D005', 'D090');
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_rkpf_rsnum         ON rkpf (rsnum);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_rsadd_rsnum_rspos  ON rsadd (rsnum, rspos);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_lips_rsnum_rspos   ON lips (rsnum, rspos);

-- ------------------------------------------------------------- materiais
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_makt_matnr_spras   ON makt (matnr, spras);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mara_matnr         ON mara (matnr);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_mara_scm_matid     ON mara (scm_matid_guid16);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_aqua_matid         ON "/scwm/aqua" (matid) WHERE quan > 0;

-- --------------------------------------------------------- fontes não-SAP
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_uca_armac_data
    ON fastfield.relatorio_entrada_saida_uca (n_armac, created_at_form DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_hourmeter_armac_dt
    ON total_integration.hourmeter (armac_code, event_datetime DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_hourmeter_inv_armac_dt
    ON total_integration.hourmeter_invalid (armac_code, event_datetime DESC);


-- =============================================================================
-- Depois de criar tudo:
-- =============================================================================
-- ANALYZE aufk; ANALYZE afih; ANALYZE afko; ANALYZE afvc; ANALYZE crhd;
-- ANALYZE jest; ANALYZE eban; ANALYZE ekpo; ANALYZE ekko; ANALYZE ekbe;
-- ANALYZE resb; ANALYZE makt; ANALYZE mara;

-- Para medir antes/depois:
-- EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <cole a query aqui>;


-- ------------------------------------------------- [NACIONAL r2] expressão
-- Os joins de status usam TRIM(objnr)/TRIM(stsma) porque nesta réplica essas
-- colunas vêm com padding. Índices simples de coluna não servem para eles;
-- estes índices de expressão devolvem o index-scan:
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_jest_objnr_trim
    ON jest (TRIM(BOTH FROM objnr), stat) WHERE COALESCE(inact, '') <> 'X';
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_jsto_objnr_trim
    ON jsto (TRIM(BOTH FROM objnr));
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_tj30t_stsma_trim
    ON tj30t (TRIM(BOTH FROM stsma), estat, spras);
