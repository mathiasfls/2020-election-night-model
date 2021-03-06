library(dplyr)
library(quantreg)
library(readr)
library(tidyr)
library(tibble)

source('utilities.R')

fit_quantile_reg_model = function(data, tau, weights) {
  reg = rq(residuals ~ . -1 - total_voters, data=data, tau=tau, weights=weights)
  return(reg)
}

get_county_predictions = function(observed_data_features, unobserved_data_features, model_settings) {
  method = model_settings$method
  
  weights = observed_data_features$total_voters
  observed_data_features = observed_data_features %>% 
  mutate(residuals=residuals / total_voters)
  
  reg = fit_quantile_reg_model(observed_data_features, 0.5, weights)

  preds = predict(reg, unobserved_data_features)
  preds = preds * unobserved_data_features$total_voters
  
  return(preds)
}

# this computes conformal confidence intervals. we only get marginal (not conditional confidence interval).
get_county_confidence_intervals = function(observed_data_features, unobserved_data_features, alpha, model_settings, fixed_effects) {
  n_fixed_effects = length(fixed_effects)
  
  # we need the contraint rows to be in t_data. so I remove them from observed_data_features
  if (n_fixed_effects > 0) {
    fixed_effects_constraint_rows = tail(observed_data_features, n_fixed_effects)
    observed_data_features = head(observed_data_features, dim(observed_data_features)[1] - n_fixed_effects)
  }
  shuffle = sample(nrow(observed_data_features)) # shuffle to create training and conformal set
  observed_data_features_shuffled = observed_data_features[shuffle,]
  conf_frac = min(1 - (alpha / 0.05) / nrow(observed_data_features_shuffled), 0.9) # fraction for conformal is at least 10%
  t_rows = floor(nrow(observed_data_features_shuffled) * conf_frac)
  t_data = observed_data_features_shuffled[1:t_rows,] # first t_rows are training set
  if (n_fixed_effects > 0) {
    # since we split observed_data_features it is now possible that some fixed effect columns will be all zero. We drop those to avoid singular design issues
    t_data = t_data %>% select(where(~ any(. != 0))) # drop column if all examples are in c_data
    # now the columns between t_data and the contraint rows are different. so we only take the columns from the constraint
    # rows that also appear in t_data and then row bind the to the end
    t_data = t_data %>% rbind((fixed_effects_constraint_rows %>% select(colnames(t_data))))
  }
  
  c_data = observed_data_features_shuffled[(t_rows + 1):nrow(observed_data_features_shuffled), ] # other rows are conformal set
  
  upper = (1 + alpha) / 2
  lower = (1 - alpha) / 2

  weights = t_data$total_voters
  t_data = t_data %>% mutate(residuals=residuals / total_voters) # scaled error
  c_data = c_data %>% mutate(residuals=residuals / total_voters) # scaled error
        
  reg_bounds = fit_quantile_reg_model(t_data, c(lower, upper), weights)

  c_bounds = predict(reg_bounds, c_data)
  qr_bounds = predict(reg_bounds, unobserved_data_features)
  
  # c_bounds is guess for upper and lower bounds
  # c_ub and c_lb how much we miss are outside of confidence intervals
  c_ub = c_data$residuals - c_bounds[,2]
  c_lb = c_bounds[,1] - c_data$residuals
  scores = pmax(c_lb, c_ub) # this is e_j
  
  # our desired coverage is that alpha-% percentile of e_j should be less than 0 
  # this is roughly equivalent to alpha-% of c_data is covered by initial guess
  # to get there we need to add the correction, which is equal to alpha * (1 + 1/nrow(c_data))
  correction = quantile(scores, probs=c(alpha * (1 + 1/nrow(c_data))))
  
  # we care about larger counties more than smaller counties when computing state
  # prediction intervals. to accomplish this, we will weight the i-th score by the 
  # number of voters in that county in the previous election 
  weights = c_data$total_voters / sum(c_data$total_voters)
  pop_corr = as_tibble(cbind(scores, weights)) %>% arrange(scores) %>% 
    mutate(perc = cumsum(weights)) %>% filter(perc > alpha * (1 + 1/nrow(c_data)))
  pop_corr = min(pop_corr$scores)
  if (model_settings$robust) {
    correction = max(correction, pop_corr)
  } else {
    correction = pop_corr # "unbiased" state PIs
  }
  
  qr_bounds[,2] = qr_bounds[,2] + correction
  qr_bounds[,1] = qr_bounds[,1] - correction
  qr_bounds = qr_bounds * unobserved_data_features$total_voters
  
  return(list(lower=qr_bounds[,1], upper=qr_bounds[,2]))
}

# this function gets the aggregate votes for geographic units made up of counties.
# it sums to the required level (state, cd, county category) and then adds in the unecpected data if necessary.
get_observed_votes_aggregate = function(observed_data, observed_unexpected_data, aggregate) {
  observed_data_known_votes = observed_data %>% 
    group_by(.dots=aggregate) %>%
    summarize(observed_data_votes=sum(results), .groups='drop')
  
  aggregate_votes = NULL
  # since we don't know the county category or congressional district (??) of unexpected counties
  # we can't add them back in. So we only add unexpected data if aggregate is postal_code.
  # unfortunately r is bad, and this is the best way to check this?
  if (length(aggregate) == 1) {
    observed_unexpected_data_known_votes = observed_unexpected_data %>%
      group_by(.dots=aggregate) %>%
      summarize(observed_unexpected_data_votes=sum(results), .groups='drop')
    
    # the full join here makes sure that if entire congressional districts or county categories
    # are unexpectedly present, we will capture them. This is also why we need to replace_NA with zero
    # NA here means that there were no such counties, so they contribute zero votes.
    aggregate_votes = observed_data_known_votes %>%
      full_join(observed_unexpected_data_known_votes, by=aggregate) %>%
      replace_na(list(observed_data_votes=0, observed_unexpected_data_votes=0)) %>%
      mutate(results=observed_data_votes + observed_unexpected_data_votes) %>%
      select(all_of(c(aggregate, 'results')))
  } else {
    aggregate_votes = observed_data_known_votes %>%
      mutate(results=observed_data_votes) %>%
      select(all_of(c(aggregate, 'results')))
  }
  return(aggregate_votes)
}

# This function returns the predictions for state, cd, county category
# predictions are made up of known results in observed counties (also within the prediction column)
# and predicted votes for unobserved counties
get_aggregate_predictions = function(observed_data, unobserved_data, observed_unexpected_data, aggregate) {
  
  # first get only the aggregate votes from observed counties (both expected and unexpevted)
  aggregate_votes = get_observed_votes_aggregate(observed_data, observed_unexpected_data, aggregate)
  
  aggregate_preds = unobserved_data %>%
    group_by(.dots=aggregate) %>%
    summarize(pred_only=sum(pred), .groups='drop')
  
  # the full join accounts for if entire states, cd, or county categories are either observed or predicted. 
  aggregate_data = aggregate_votes %>%
    full_join(aggregate_preds, by=aggregate) %>%
    replace_na(list(results=0, pred_only=0)) %>%
    mutate(pred=results + pred_only) %>%
    arrange(!!!syms(aggregate)) %>% # this allows aggregate to be a vector of strings
    select(all_of(c(aggregate, 'pred')))
  
  return(aggregate_data)
}

# this function produces aggregate confidence intervals for state, cd, county category level
get_aggregate_confidence_intervals = function(observed_data, unobserved_data, observed_unexpected_data, aggregate, lower_string, upper_string) {
  
  aggregate_votes = get_observed_votes_aggregate(observed_data, observed_unexpected_data, aggregate)
  
  # confidence intervals just sum, kinda miraculous
  aggregate_confidence_intervals = unobserved_data %>%
    group_by(.dots=aggregate) %>%
    summarize(predicted_lower=sum(!!sym(lower_string)), predicted_upper=sum(!!sym(upper_string)), .groups='drop')
  # since lower and upper string are always just strings, we can use !!sym(x) instead of !!!syms(x) as with aggregate
  
  aggregate_data = aggregate_votes %>%
    full_join(aggregate_confidence_intervals, by=aggregate) %>%
    replace_na(list(results=0, predicted_lower=0, predicted_upper=0)) %>%
    mutate(lower=predicted_lower + results, upper=predicted_upper + results) %>%
    arrange(!!!syms(aggregate)) %>%
    select(all_of(c(aggregate, 'lower', 'upper')))
  
  return(aggregate_data)
}

estimate = function(current_data, model_settings=list(fixed_effects=c(), robust=FALSE), confidence_intervals=c(0.8)) {
  fixed_effects = model_settings$fixed_effects
  
  preprocessed_data = get_preprocessed_data() %>%
    select(postal_code, geographic_unit_fips, last_election_results, total_voters)
  
  # joining current results to preprocessed data. This is a left_join on the preprocessed data, that means
  # if we didn't expect the county, we drop it. This is because we don't have any covariates for it.
  # we solve this by using observed_unexpected_data below, which we then add into state, cd, county category totals
  data = preprocessed_data %>% left_join(current_data, by=c("postal_code", "geographic_unit_fips"))
  
  observed_data = data %>%
    filter(precincts_reporting_pct >= 100) %>%   # these are the counties that we have observed
    mutate(residuals=results - last_election_results) # residual
  
  unobserved_data = data %>% 
    filter(precincts_reporting_pct < 100 | is.na(results)) %>%
    mutate(residuals=NA)
  
  # these are observed counties that we were not expecting (mostly for townships). We add these
  # results back in later to get state totals
  observed_unexpected_data = current_data %>% 
    filter(precincts_reporting_pct >= 100) %>%
    filter(!geographic_unit_fips %in% preprocessed_data$geographic_unit_fips)
  
  # extract features for observed and unobserved counties specifically
  features_to_remove = c("postal_code","geographic_unit_name", "geographic_unit_fips", "last_election_results", "results", "precincts_reporting_pct")
  features_to_remove = setdiff(features_to_remove, fixed_effects) # we want to keep the feature if we want a fixed effect for it
  
  observed_data_features = observed_data %>% 
    select(-c(all_of(features_to_remove))) %>%
    mutate(intercept=1)
  
  unobserved_data_features = unobserved_data %>%
    select(-c(all_of(features_to_remove), residuals)) %>% 
    mutate(intercept=1)
  
  for (fixed_effect in fixed_effects) {
    # for each fixed effect we want to turn the string column into categorical variables. We need to do this, over using levels because
    # there might be unseen fixed effects that we don't want to learn anything for
    # to fix issues with with singular matrix design we add a constraint row, which has all fixed effects but no intercept and no residual
    # this contrains the solutions set.
    fixed_effect_prefix = paste(fixed_effect, '_', sep="")
    observed_data_features = observed_data_features %>%
      pivot_wider(names_from=fixed_effect, values_from=fixed_effect, names_prefix=fixed_effect_prefix) %>% #turn categorical variable into columns
      mutate_at(vars(starts_with(fixed_effect_prefix)), funs(ifelse(is.na(.), 0, 1))) %>% # replace values with 1 and NA with 0s
      select(-starts_with(paste(fixed_effect_prefix, '0', sep=""))) %>% # if we have more than one fixed effect, we have an additional zero column for the previous fixed effects that we want to get rid of
      add_row() %>% # we add a row full of NAs
      replace(is.na(.), 0) %>% # we replace the NAs with zero
      mutate_at(vars(starts_with(fixed_effect_prefix)), funs(case_when(intercept == 0 ~ 1, TRUE ~ .))) %>% # we set all possible fixed effects variables to 1, except the intercept that is 0
      mutate_at('total_voters', funs(case_when(intercept == 0 ~ 1, TRUE ~ .))) # we give that new row 1 total voter, so that when we compute weight we don't get (0/0=) NA
    
    unobserved_data_features = unobserved_data_features %>%
      mutate(row=row_number()) %>%
      pivot_wider(names_from=fixed_effect, values_from=fixed_effect, names_prefix=fixed_effect_prefix) %>% # we do the same for unobserved counties
      select(-row) %>%
      mutate_at(vars(starts_with(fixed_effect_prefix)), funs(ifelse(is.na(.), 0, 1)))
    
    # there might be fixed effect categories that appear in observed data only. we add those manully to unseen counties and set them to 0
    # we don't need to worry about fixed effect categories that appear in unseen data only, since we don't need to learn a coefficient for those
    for (col_name in colnames(observed_data_features)) {
      if (startsWith(col_name, fixed_effect_prefix) & !(col_name %in% colnames(unobserved_data_features))) {
        unobserved_data_features[col_name] = 0
      }
    }
  }
  
  # for observed counties prediction is just the results
  # for unobserved counties prediction is the estimated residual between the last and current election. So we 
  # add in the last election result to get our estimate for current election result. We max that with the results
  # we've seen so far to make sure the counted vote isn't more than the prediction.
  county_predictions = get_county_predictions(observed_data_features, unobserved_data_features, model_settings)
  observed_data['pred'] = observed_data$results
  unobserved_data['pred'] = pmax(county_predictions + unobserved_data$last_election_results, unobserved_data$results)
  observed_unexpected_data['pred'] = observed_unexpected_data$results
  
  # get aggregate predictions for state
  state_data = get_aggregate_predictions(observed_data, unobserved_data, observed_unexpected_data, 'postal_code')

  # for observed counties, lower and upper confidence intervals are predictions
  for (alpha in confidence_intervals) {
    lower_string = paste('lower', alpha, sep='_')
    upper_string = paste('upper', alpha, sep='_')
    
    county_confidence_intervals = get_county_confidence_intervals(observed_data_features, unobserved_data_features, alpha, model_settings, fixed_effects)
    observed_data[lower_string] = observed_data$results
    observed_data[upper_string] = observed_data$results
    unobserved_data[lower_string] = pmax(county_confidence_intervals$lower + unobserved_data$last_election_results, unobserved_data$results)
    unobserved_data[upper_string] = pmax(county_confidence_intervals$upper + unobserved_data$last_election_results, unobserved_data$results)
    observed_unexpected_data[lower_string] = observed_unexpected_data$results
    observed_unexpected_data[upper_string] = observed_unexpected_data$results
    
    state_confidence_intervals = get_aggregate_confidence_intervals(observed_data, unobserved_data, observed_unexpected_data, 'postal_code', lower_string, upper_string)
    state_data[lower_string] = state_confidence_intervals$lower
    state_data[upper_string] = state_confidence_intervals$upper
  }
  
  county_data = observed_data %>%
    bind_rows(unobserved_data) %>%
    bind_rows(observed_unexpected_data) %>%
    arrange(geographic_unit_fips) %>%
    select(postal_code, geographic_unit_fips, pred, starts_with('lower'), starts_with('upper'))
  
  return(list(county_data=county_data, state_data=state_data))
}