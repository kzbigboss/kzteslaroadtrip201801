# clear environment
rm(list=ls())
cat("\014")

# load libraries
library(dplyr) #for data manipulation
library(DBI) #for interfacing with a database
library(zoo) #for backfilling NAs along time series
#library(rwunderground) #for downloading weater, deprecated
library(lubridate) #for date/time manupluation
library(jsonlite) #for parsing through JSON
library(knitr)

# set working directory
setwd('/Users/kazzazmk/WorkDocs/Repo/kzteslaroadtrip2018')

# load data
raw_tesladata <- readRDS('data/kztesla.RDS')

# create subset for summary table
summary_tesla <- raw_tesladata %>%
  filter(trip_day != 0) %>% # ignoring data outside the bound of our roadtrip 
  filter(trip_event == 'transit') %>% # ignoring overnight charging sessions
  group_by(trip_day) %>%
  summarize(od_start = min(odometer)
            ,od_end = max(odometer)
            ,time_start = min(timestamp)
            ,time_end = max(timestamp)
            ,avg_temp_f = round(mean(outside_temp_f),1)
            ,miles_traveled = round(od_end - od_start,1)
            ) %>%
  ungroup(.) %>%
  select(-od_start, -od_end) %>%
  mutate(running_miles = cumsum(miles_traveled)
         ,time_hrs = round(difftime(time_end, time_start, unit='hours'),1)
         ,time_hrs = as.numeric(time_hrs)
         ,run_time = cumsum(time_hrs)
         ) %>%
  select(-time_start, -time_end)

kable(summary_tesla)


# create subset for charging questions
charge_tesla <- raw_tesladata %>%
  filter(trip_day != 0) %>% # ignoring data outside the bound of our roadtrip 
  filter(trip_event == 'transit') %>% # ignoring overnight charging sessions
  select(unixtime, timestamp, trip_day, trip_event, battery_level, outside_temp_f, latitude, longitude, contains('charge_state'))

### create subset focused on start/end times
charge_start_end <- charge_tesla %>%
  select(unixtime, timestamp, trip_day, trip_event
         ,battery_level, outside_temp_f, latitude, longitude
         ,charge_state_charging_state, charge_state_charge_miles_added_rated
         ,charge_state_charge_miles_added_ideal
         ) %>%
  # find the instance where the charge state changed
  mutate(charge_state_charging_state = if_else(charge_state_charging_state == 'Starting'
                                               , 'Charging'
                                               , charge_state_charging_state)
         ) %>%
  mutate(event_time = if_else(charge_state_charging_state == lag(charge_state_charging_state)
                              , 'SAME'
                              , 'CHANGE'
                              )
         ) %>%
  filter(event_time == 'CHANGE') %>% # focus on where changes occured
  mutate(next_timestamp = lead(timestamp)) %>% # peek ahead to see when the charge state ended
  filter(charge_state_charging_state == 'Charging') %>% # drop records where changing stopped
  mutate(duration = as.numeric(next_timestamp - timestamp)) # calculate charge duration 

# summare charge data
charge_start_end_summary <- charge_start_end %>%
  group_by(trip_day) %>%
  summarize(charges = n()
            ,chrg_time_hrs = round(sum(duration) / 60,1)
            ) %>%
  ungroup(.) %>%
  mutate(running_chrg_time_hrs = cumsum(chrg_time_hrs))

kable(charge_start_end_summary)

# what if: charge time was only 30 minutes |OR| there were no charge stops
reduced_stops <- summary_tesla %>%
  left_join(charge_start_end_summary) %>%
  select(trip_day, time_hrs, chrg_time_hrs, charges) %>%
  mutate(time_hrs_red_chrg = time_hrs - chrg_time_hrs + (charges * .5)
         ,time_hrs_no_chrg = time_hrs - chrg_time_hrs
         ) %>%
  select(-chrg_time_hrs, -charges) %>%
  mutate(running_time_hrs = cumsum(time_hrs)
         ,running_time_red_hrs = cumsum(time_hrs_red_chrg)
         ,running_time_no_hrs = cumsum(time_hrs_no_chrg)
         )

kable(reduced_stops %>% select(trip_day, time_hrs, time_hrs_red_chrg, time_hrs_no_chrg))
kable(reduced_stops %>% select(trip_day, running_time_hrs, running_time_red_hrs, running_time_no_hrs))
