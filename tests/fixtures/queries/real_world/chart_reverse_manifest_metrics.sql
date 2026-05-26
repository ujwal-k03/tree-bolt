-- QUERY_SOURCE: CHART_QUERY
-- || Slice ID: 12588 || 
SELECT date_trunc('day', CAST(manifest_date AS TIMESTAMP)) AS manifest_date,
       carrier AS carrier,
       dc_code AS dc_code,
       count(distinct awb_num) AS reverse_manifest_vol,
       count(distinct case
                          when reverse_closed_status = 'pick' then awb_num
                      end) AS pick_vol,
       coalesce(100.00*count(distinct case
                                          when reverse_closed_status = 'pick' then awb_num
                                      end)/nullif(count(distinct awb_num), 0), 0) AS "pick%",
       count(distinct case
                          when reverse_closed_status = 'qcf' then awb_num
                      end) AS qcf_vol,
       coalesce(100.00*count(distinct case
                                          when reverse_closed_status = 'qcf' then awb_num
                                      end)/nullif(count(distinct awb_num), 0), 0) AS "qcf%",
       count(distinct case
                          when reverse_closed_status = '3p_cncl'
                               and reverse_verified_cancel=1 then awb_num
                      end) AS cncl_3pc_verified_vol,
       coalesce(100.00*count(distinct case
                                          when ofp_flag=1
                                               and reverse_closed_status = '3p_cncl'
                                               and reverse_verified_cancel=1 then awb_num
                                      end)/nullif(count(distinct awb_num), 0), 0) AS "cncl_3pc_verified%"
FROM
  (with dcml as
     (select distinct lower(coalesce(case
                                         when lm_location like '%/%' then reverse(split(lm_location, '/'))[1]
                                         when lm_location like '%-%' then reverse(split(lm_location, '-'))[1]
                                         when lm_location like '%_%' then reverse(split(lm_location, '_'))[1]
                                         when lm_location like '% %' then reverse(split(lm_location, ' '))[1]
                                         else lm_location
                                     end, case
                                              when lm_code like '%/%' then reverse(split(lm_code, '/'))[1]
                                              when lm_code like '%-%' then reverse(split(lm_code, '-'))[1]
                                              when lm_code like '%_%' then reverse(split(lm_code, '_'))[1]
                                              when lm_code like '% %' then reverse(split(lm_code, ' '))[1]
                                              else lm_code
                                          end, case
                                                   when dc_code like '%/%' then reverse(split(dc_code, '/'))[1]
                                                   when dc_code like '%-%' then reverse(split(dc_code, '-'))[1]
                                                   when dc_code like '%_%' then reverse(split(dc_code, '_'))[1]
                                                   when dc_code like '% %' then reverse(split(dc_code, ' '))[1]
                                                   else dc_code
                                               end)) AS lm_dc_code,
                      min(col1) as dc_state,
                      min(lower(area_manager)) as area_manager,
                      min(lower(cluster_head)) as cluster_head,
                      min(lower(zonal_head)) as zonal_head
      from mercury.delivery_center_master_laap_v2
      group by 1),
        dc_classification as
     (select coalesce(lower(case
                                when rto_lm_location like '%/%' then reverse(split(rto_lm_location, '/'))[1]
                                when rto_lm_location like '%-%' then reverse(split(rto_lm_location, '-'))[1]
                                when rto_lm_location like '% %' then reverse(split(rto_lm_location, ' '))[1]
                                when rto_lm_location like '%_%' then reverse(split(rto_lm_location, '_'))[1]
                                else rto_lm_location
                            end), lower(manifest_dc_code))as lm_code,
             min(date(reverse_first_ofp_time at time zone 'Asia/Calcutta')) as min_created_date
      from platinum.order_awb_entity
      where order_date >=current_date - interval '180' day
        and fulfilment_leg='reverse'
        and request_type in (1,
                             4)
        and misroute_lm is null
        and carrier = 'meeshologistics'
      group by 1),
        non_laap_dcs as
     (select metric_date,
             value,
             location
      from gold.valmo_serviceability_2k24
      where metric_date >=current_date - interval '120' day
        and movement_type = 'return'
        and key = 'user_pin'
        and facility = 'LM'
        and metric_date_type='reverse_created' ),
        main as
     (select awb_num,
             sub_order_num,
             carrier,
             user_pin,
             user_city,
             user_state,
             user_tier,
             lower(case
                       when rto_lm_location like '%/%' then reverse(split(rto_lm_location, '/'))[1]
                       when rto_lm_location like '%-%' then reverse(split(rto_lm_location, '-'))[1]
                       when rto_lm_location like '%_%' then reverse(split(rto_lm_location, '_'))[1]
                       when rto_lm_location like '% %' then reverse(split(rto_lm_location, ' '))[1]
                       else rto_lm_location
                   end) as rto_lm_location,
             lower(case
                       when manifest_dc_code like '%/%' then reverse(split(manifest_dc_code, '/'))[1]
                       when manifest_dc_code like '%-%' then reverse(split(manifest_dc_code, '-'))[1]
                       when manifest_dc_code like '%_%' then reverse(split(manifest_dc_code, '_'))[1]
                       when manifest_dc_code like '% %' then reverse(split(manifest_dc_code, ' '))[1]
                       else manifest_dc_code
                   end) as manifest_dc_code,
             case
                 when reverse_first_ofp_time is null
                      and misroute_lm is not null then lower(case
                                                                 when current_connection_location like '%/%' then reverse(split(current_connection_location, '/'))[1]
                                                                 when current_connection_location like '%-%' then reverse(split(current_connection_location, '-'))[1]
                                                                 when current_connection_location like '%_%' then reverse(split(current_connection_location, '_'))[1]
                                                                 when current_connection_location like '%%' then reverse(split(current_connection_location, ' '))[1]
                                                                 else current_connection_location
                                                             end)
                 else lower(coalesce(case
                                         when rto_lm_location like '%/%' then reverse(split(rto_lm_location, '/'))[1]
                                         when rto_lm_location like '%-%' then reverse(split(rto_lm_location, '-'))[1]
                                         when rto_lm_location like '%_%' then reverse(split(rto_lm_location, '_'))[1]
                                         when rto_lm_location like '% %' then reverse(split(rto_lm_location, ' '))[1]
                                         else rto_lm_location
                                     end, manifest_dc_code))
             end as dc_code,
             manifestation_time at time zone 'Asia/Calcutta' as manifestation_time,
             date(manifestation_time at time zone 'Asia/Calcutta') as manifest_date,
             date(reverse_first_ofp_time at time zone 'Asia/Calcutta') as fofp_date,
             date(reverse_pickup_time at time zone 'Asia/Calcutta') as reverse_pickup_date,
             rto_delivered_time,
             date_diff('day', date(manifestation_time at time zone 'Asia/Calcutta'), date(reverse_pickup_time at time zone 'Asia/Calcutta')) as m2p_day,
             date_diff('hour', manifestation_time at time zone 'Asia/Calcutta',reverse_pickup_time at time zone 'Asia/Calcutta') as m2p,
             date_diff('hour', manifestation_time at time zone 'Asia/Calcutta',reverse_first_ofp_time at time zone 'Asia/Calcutta') as m2fofp,
             date_diff('day', manifestation_time at time zone 'Asia/Calcutta',reverse_first_ofp_time at time zone 'Asia/Calcutta') as m2fofp_day,
             date_diff('hour', reverse_first_ofp_time at time zone 'Asia/Calcutta',reverse_pickup_time at time zone 'Asia/Calcutta') as fofp2p,
             date_diff('day', date(reverse_first_ofp_time at time zone 'Asia/Calcutta'), date(reverse_pickup_time at time zone 'Asia/Calcutta')) as fofp2p_day,
             row_number()over(partition by request_id
                              order by manifestation_time) as awb_rk,
             date_diff('hour', manifestation_time at time zone 'Asia/Calcutta', reverse_closed_time at time zone 'Asia/Calcutta') as m2c,
             date_diff('day', manifestation_time at time zone 'Asia/Calcutta', reverse_closed_time at time zone 'Asia/Calcutta') as m2c_day,
             reverse_closed_status,
             reverse_closed_time,
             date(reverse_closed_time at time zone 'Asia/Calcutta') as reverse_closed_date,
             lead(carrier)over(partition by request_id
                               order by manifestation_time) as next_carrier,
             lag(carrier)over(partition by request_id
                              order by manifestation_time) as prev_carrier,
             lead(reverse_closed_status)over(partition by request_id
                                             order by manifestation_time) as next_reverse_closed_status,
             case
                 when reverse_first_ofp_time is not null then 1
                 else 0
             end as ofp_flag,
             reverse_ofp_count,
             reverse_cancelled_by,
             case
                 when reverse_verified_cancel=1 then 1
                 else 0
             end as reverse_verified_cancel,
             qc_flag,
             qc_flag_v2,
             wpr_flag,
             request_type,
             last_mile_player,
             mid_mile_player,
             first_mile_player,
             misroute_lm,
             carrier_id,
             fulfilment_leg,
             actual_delivery_time,
             request_type
      from platinum.order_awb_entity
      where order_date >=current_date - interval '180' day
        and date(cast(first_request_time as timestamp) at time zone 'Asia/Calcutta') >= current_date - interval '100' day
        and fulfilment_leg='reverse'
        and request_type in (1,
                             2,
                             4)
        AND actual_delivery_time IS NOT NULL ) select main.*,
                                                      a.dc_state,
                                                      CONCAT(user_pin, '_', dc_code) AS pin_dc,
                                                      a.area_manager,
                                                      a.cluster_head,
                                                      a.zonal_head,
                                                      case
                                                          when date_diff('day', dcc.min_created_date, manifest_date)<=14 then 'New'
                                                          when date_diff('day', dcc.min_created_date, manifest_date)<=28 then 'Stable'
                                                          when date_diff('day', dcc.min_created_date, manifest_date)> 28 then 'Matured'
                                                          else 'NA'
                                                      end as dc_split,
                                                      case
                                                          when date_diff('day', dcc.min_created_date, manifest_date)<=28 then 'Non-Matured'
                                                          when date_diff('day', dcc.min_created_date, manifest_date)> 28 then 'Matured'
                                                          else 'NA'
                                                      end as matured_dc
   from main
   inner join non_laap_dcs b on b.value = main.user_pin
   and b.metric_date = main.manifest_date
   left join dcml a on a.lm_dc_code = main.dc_code
   left join dc_classification dcc on dcc.lm_code = coalesce(main.dc_code, b.location)
   where manifest_date >= current_date - interval '100' day) AS virtual_table
WHERE manifest_date >= DATE '2025-06-16'
  AND manifest_date < DATE '2025-07-27'
  AND carrier IN ('meeshologistics')
GROUP BY date_trunc('day', CAST(manifest_date AS TIMESTAMP)),
         carrier,
         dc_code
ORDER BY 1 desc,
         2 DESC
LIMIT 100