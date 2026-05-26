create or replace table hive_metastore.scrap.ug_cohort_all_last_rc_flag as
select distinct
    cast(user_id as string) as user_id,
    current_date - interval '1' day as dim_dt,
    case
       when rc_flag = 'Reseller' then rc_flag
       else 'Consumer'
    end as last_rc_flag 
from gold.user_master_bi_lite
where user_id is not null