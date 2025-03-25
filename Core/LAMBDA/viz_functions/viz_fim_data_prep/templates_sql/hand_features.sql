SELECT
    fs.hand_id,
    fs.feature_id,
    CONCAT(LPAD(fs.huc8::text, 8, '0'), '-', fs.branch) as huc8_branch,
    LEFT(LPAD(fs.huc8::text, 8, '0'), 6) as huc,
    fs.hydro_id,
    fs.discharge_cms AS streamflow_cms, --TODO: Update here and in lambda to dischargem
    rf.high_water_threshold
FROM {db_fim_table}_flows fs
JOIN derived.recurrence_flows_{domain} rf ON rf.feature_id=fs.feature_id
WHERE
    fs.prc_status = 'Pending'