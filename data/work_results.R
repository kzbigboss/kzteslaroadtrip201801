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

# set working directory
setwd('/Users/kazzazmk/WorkDocs/Repo/2018-kazzazteslaroadtrip')

# source supporting files
source("creds/creds.r")

# define functions

## parse through json statements as a column from db results
parse_json <- function(json_frame, prefix){
  for (i in json_frame){
    json_parse <- as_tibble(unlist(fromJSON(i))) 
    json_parse <- as_tibble(cbind(nms = names(json_parse), t(json_parse))) %>% 
      mutate_all(as.character) #mutating to chr to avoid data typ mismatches when unionion
    if (!exists('json_stack')){
      json_stack <- json_parse
    }else{
      json_stack <- json_stack %>% union_all(json_parse)
    }
  }
  
  json_stack <- json_stack %>% select(-nms)
  
  colnames(json_stack) <- paste(prefix, colnames(json_stack), sep = "_")
  
  json_stack <- json_stack %>% mutate(join_rownum = row_number())
  
  return(json_stack)
}

## add an event label based off unix timestamp
determine_label_event <- function(unixtimestamp){
  result = man_trip_times$event[unixtimestamp >= man_trip_times$start & unixtimestamp <= man_trip_times$end]
  result = if(length(result) == 0L){'out of bounds'}else{result}
  return(result)
}

## add an event day based off unit timestamp
determine_label_day <- function(unixtimestamp){
  result = man_trip_times$day[unixtimestamp >= man_trip_times$start & unixtimestamp <= man_trip_times$end]
  result = if(length(result) == 0L){0}else{result}
  return(result)
}

# connect to db and download results
db <- src_mysql(user = Sys.getenv('db_user')
                , password = Sys.getenv('db_pass')
                , dbname = Sys.getenv('db_name')
                , host = Sys.getenv('db_host')
                )

raw_tesladata <- as_tibble(tbl(db, 'tesla_data'))

# apply some basic transforms
worked_tesladata <- raw_tesladata %>%
  mutate(unixtime = timestamp
         ,timestamp = as.POSIXct(timestamp, tz = 'UTC', origin = '1970-01-01')
         ,outside_temp_f = na.locf(outside_temp_f, na.rm = FALSE) # backfill NAs with previously recorded outside_temp_f
         ,inside_temp_f = na.locf(inside_temp_f, na.rm = FALSE) # backfill NAs with previously recorded inside_temp_f
         ,join_rownum = row_number() # add rownum column to accomodate join to parsed JSON data
         ) %>%
  select(-charge_state, -climate_state, -drive_state, -vehicle_state)

# declare state/end times of the road trip

man_trip_times <- frame_data(
  ~'day', ~'event', ~'start', ~'end',            # recording in epoch time
  1, 'transit', 1514830569, 1514874446,          # Chicago to Omaha
  1, 'overnight charge', 1514874507, 1514912977, # Omaha hotel
  2, 'transit', 1514913039, 1514954481,          # Omaha to Denver
  2, 'overnight charge', 1514954543, 1514998907, # Denver hotel
  3, 'transit', 1514998968, 1515038915,          # Denver to Salt Lake City
  3, 'overnight charge', 1515038975, 1515085120, # Salt Lake City hotel
  4, 'transit', 1515085181, 1515120812,          # Salt Lake City to Reno
  4, 'overnight charge', 1515120872, 1515184304, # Reno hotel
  5, 'transit', 1515184364, 1515207813           # Reno to Cupterino
  ) %>%
  mutate(duration = end - start
         ,running_duration = cumsum(duration)
         )

# tag data entires with day/event lables
worked_tesladata$trip_day   <- unlist(lapply(worked_tesladata$unixtime, determine_label_day))
worked_tesladata$trip_event <- unlist(lapply(worked_tesladata$unixtime, determine_label_event))


# parse json features from raw tesla data
raw_tesladata_climate_state   <- parse_json(raw_tesladata$climate_state, 'climate_state')
raw_tesladata_drive_state     <- parse_json(raw_tesladata$drive_state, 'drive_state')
raw_tesladata_vehicle_state   <- parse_json(raw_tesladata$vehicle_state, 'vehicle_state')
raw_tesladata_charge_state   <- parse_json(raw_tesladata$charge_state, 'charge_state')

# join everything into a final file for analysis
joined_tesladata <- worked_tesladata %>%
  left_join(raw_tesladata_climate_state) %>%
  left_join(raw_tesladata_drive_state) %>%
  left_join(raw_tesladata_vehicle_state) %>%
  left_join(raw_tesladata_charge_state)

#save output for Tableau
write.csv(joined_tesladata, file = 'kztesla.csv', quote = FALSE, row.names = FALSE)
saveRDS(joined_tesladata, 'kztesla.rds')
