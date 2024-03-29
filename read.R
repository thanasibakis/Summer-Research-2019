library(R.matlab)
library(parallel)
library(dplyr)


# Converts the Matlab matrix data in the given .mat file to an R data frame
read.eeg.mat = function(path.to.mat)
{
  ## First, check if we already converted this matlab file to our .RData format
  
  dir.create("./data", showWarnings = F) # don't show warning if already exists
  
  rdata.file.name = path.to.mat %>% 
    extract.file.name() %>%
    paste("./data/", . , ".RData", sep = '')
  
  if(file.exists(rdata.file.name))
  {
    print("Formatted RData exists, reading it directly...")
    
    load(rdata.file.name)
    return(list(N200.Data = N200.data, P300.Data = P300.data, Info = eeg.info))
  }
  
  ## Begin formatting by loading the filtered EEG data
  
  eeg.matlab = read.mat.file(path.to.mat)
  
  N200.data = eeg.matlab$stimlocked[[3]]
  P300.data = eeg.matlab$stimlocked[[11]]
  num.trials = dim(N200.data)[2]
  
  sample.rate = eeg.matlab$sr[1,1] / 1000 # in samples/ms
  num.samples = dim(N200.data)[1]
  stimulus.time.ms = match(0, eeg.matlab$stimlocked[[8]])
  sample.times = 1:num.samples / sample.rate - stimulus.time.ms # stimulus-locked sample times
  
  reaction.times.ms = eeg.matlab$expinfo[[38]] / sample.rate
  
  conditions = eeg.matlab$expinfo[[36]]
  correct = eeg.matlab$expinfo[[37]]
  
  ## Spare ourselves some memory
  
  rm(eeg.matlab)
  
  ## Create a cluster for faster function application
  
  print("Creating clusters...")
  cluster = makeCluster(4)
  clusterExport(cluster, c("sample.times", "reaction.times.ms", "conditions", "correct"),
                envir = environment()) # Important! Defaults to global env
  
  ## Convert the matrix data to a data frame format
  
  print("Formatting the EEG samples data...")
  N200.data = create.samples.df(cluster, num.trials, N200.data)
  P300.data = create.samples.df(cluster, num.trials, P300.data)
  
  print("Formatting the reaction times data...")
  eeg.info = create.trial.info.df(cluster, num.trials)
  
  stopCluster(cluster)
  
  ## Export the data frames so we don't have to do all this again next time
  
  print("Saving the formatted data for future use...")
  save(N200.data, P300.data, eeg.info, file = rdata.file.name)
  
  list(N200.Data = N200.data, P300.Data = P300.data, Info = eeg.info)
}


# Merges the results of multiple calls to read.eeg.mat, using unique trial numbers
read.sessions = function(...)
{
  sessions = lapply(list(...), read.eeg.mat)
  
  trial.count = 0
  
  for(i in 1:length(sessions))
  {
    sessions[[i]]$N200.Data$Trial = sessions[[i]]$N200.Data$Trial + trial.count
    sessions[[i]]$P300.Data$Trial = sessions[[i]]$P300.Data$Trial + trial.count
    sessions[[i]]$Info$Trial = sessions[[i]]$Info$Trial + trial.count
    
    trial.count = trial.count + length(sessions[[i]]$Info$Trial)
  }
  
  N200.Data = lapply(sessions, (function (session) session$N200.Data)) %>% bind_rows()
  P300.Data = lapply(sessions, (function (session) session$P300.Data)) %>% bind_rows()
  Info = lapply(sessions, (function (session) session$Info)) %>% bind_rows()
  
  list(N200.Data = N200.Data, P300.Data = P300.Data, Info = Info)
}


# Performs the conversion of sample data from matrix form to data frame form
create.samples.df = function(cluster, num.trials, data)
{
  df.format = function(trial) # The variables needed were exported to the cluster
    data.frame(Trial = trial,
               Sample.Val = data[, trial],
               Time.ms = sample.times)
  
  parLapply(cluster, 1:num.trials, df.format) %>%
    bind_rows()
}


# Performs the conversion of trial information from matrix form to data frame form
create.trial.info.df = function(cluster, num.trials, data)
{
  df.format = function(trial) # The variables needed were exported to the cluster
    data.frame(Trial = trial,
             Reaction.Time.ms = reaction.times.ms[trial],
             Condition = conditions[trial],
             Correct = correct[trial])
  
  parLapply(cluster, 1:num.trials, df.format) %>%
    bind_rows()
}


## Convert the .mat to .rda, but maintaining the old structure that we need to format
## This takes a long time, so check if we already did this step earlier, too
read.mat.file = function(path.to.mat)
{
  readMat.output.file.name = path.to.mat %>% 
    extract.file.name() %>%
    paste("./data/", "readMat_output-", . , ".rds", sep = '')
  
  if(file.exists(readMat.output.file.name))
  {
    print("Unformatted RDS exists, reading it directly...")
    eeg.matlab = readRDS(readMat.output.file.name)
    
  } else
  {
    print("No RDS exists, converting MAT file to RDS...")
    eeg.matlab = readMat(path.to.mat)
    
    print("Saving the unformatted RDS for future use...")
    saveRDS(eeg.matlab, readMat.output.file.name)
  }
  
  eeg.matlab
}


# Trims a path to just the file name
extract.file.name = function(path)
{
  path %>%
    strsplit("/") %>%
    unlist() %>%
    tail(n = 1) %>%
    strsplit("\\.") %>%
    unlist() %>%
    head(n = 1)
}
