mv_fx <- memoise(function(mbase, .mv.model = 'dcc', .model = 'DCC', .VAR = FALSE, 
                          .dist.model = 'mvnorm', .currency = 'JPY=X', 
                          .ahead = 1, .include.Op = TRUE, .Cl.only = FALSE, 
                          .solver = 'solnp', .roll = FALSE, .cluster = FALSE) {
  
  require(plyr, quietly = TRUE)
  require(dplyr, quietly = TRUE)
  require(quantmod, quietly = TRUE)
  
  funs <- c('filterFX.R', 'opt_arma.R', 'filter_spec.R')
  l_ply(funs, function(x) source(paste0('function/', x)))
  
  if (!is.xts(mbase)) mbase <- xts(mbase[, -1], order.by = mbase$Date)
  mbase %<>% na.omit
  
  ## Here I compare the efficiency of filtering dataset.
  ## 
  #> microbenchmark(cbind(Op(mbase[[1]]), Hi(mbase[[1]]), Lo(mbase[[1]]), Cl(mbase[[1]])))
  #Unit: milliseconds
  #expr      min       lq
  #cbind(Op(mbase[[1]]), Hi(mbase[[1]]), Lo(mbase[[1]]), Cl(mbase[[1]])) 1.557214 1.629989
  #mean   median       uq      max neval
  #1.907246 1.748483 1.981272 5.213727   100
  #> microbenchmark(mbase[[1]][,grep('Open|High|Low|Close', names(mbase[[1]]))])
  #Unit: microseconds
  #expr     min       lq     mean
  #mbase[[1]][, grep("Open|High|Low|Close", names(mbase[[1]]))] 256.581 264.9785 297.6247
  #median     uq      max neval
  #270.577 280.84 1008.597   100
  
  if (.include.Op == TRUE & .Cl.only == FALSE) { 
    mbase <- cbind(Op(mbase), Hi(mbase), Lo(mbase), Cl(mbase))
    
  } else if (.include.Op == FALSE & .Cl.only == FALSE) {
    mbase <- cbind(Hi(mbase), Lo(mbase), Cl(mbase))
    
  } else if ((.include.Op == TRUE & .Cl.only == TRUE)|
             (.include.Op == FALSE & .Cl.only == TRUE)) {
    mbase <- Cl(mbase)
    mbase %<>% na.omit
    
  } else {
    stop(".Cl.only = TRUE will strictly only get closing price.")
  }
  
  if (.cluster == TRUE) {
    cl <- makePSOCKcluster(ncol(mbase))
  } else {
    cl <- NULL
  }
	
  if (.mv.model == 'dcc') {
    
    sv <- c('solnp', 'nlminb', 'lbfgs', 'gosolnp')
    if (!.solver %in% sv) {
      stop(".solver must be %in% c('solnp', 'nlminb', 'lbfgs', 'gosolnp')")
    } else {
      .solver <- .solver
    }
    
    md <- c('DCC', 'aDCC', 'FDCC')
    if (!.model %in% md) {
      stop(".model must be %in% c('DCC', 'aDCC', 'FDCC')")
    } else {
      .model <- .model
    }
    
    ## .dist.model = 'mvt' since mvt produced most accurate outcome.
    speclist <- filter_spec(mbase, .currency = .currency, 
                            .include.Op = .include.Op, .Cl.only = .Cl.only)
    mspec <- multispec(speclist)
    
    dccSpec <- dccspec(
      mspec, VAR = .VAR, lag = 1, 
      lag.criterion = c('AIC', 'HQ', 'SC', 'FPE'), 
      external.regressors = NULL, #external.regressors = VAREXO, 
      dccOrder = c(1, 1), model = .model, 
      distribution = 'mvt') # Below article compares distribution model and 
                            #   concludes that the 'mvt' is the best.
                            # http://www.unstarched.net/2013/01/03/the-garch-dcc-model-and-2-stage-dccmvt-estimation/
    
    if (.roll == TRUE) {
      mod = dccroll(dccSpec, data = mbase, solver = .solver, 
                    forecast.length = nrow(mbase), cluster = cl)
      cat('step 1/1 dccroll done!\n')
      
    } else {
      
      ## No need multifit()
      #'@ multf <- multifit(mspec, data = mbase, cluster = cl)
      #'@ cat('step 1/3 multifit done!\n')
      
      #'@ fit <- dccfit(dccSpec, data = mbase, solver = .solver, fit = multf, 
      #'@               cluster = cl)
      #'@ cat('step 2/3 dccfit done!\n')
      fit <- dccfit(dccSpec, data = mbase, solver = .solver, cluster = cl)
      cat('step 1/2 dccfit done!\n')
      
      fc <- dccforecast(fit, n.ahead = .ahead, cluster = cl)
      #'@ cat('step 3/3 dccforecast done!\n')
      cat('step 2/2 dccforecast done!\n')
    }
    
  } else if (.mv.model == 'go-GARCH') {
    
    armaOrder <- opt_arma(mbase)
    
    md <- c('constant', 'AR', 'VAR')
    if (!.model %in% md) {
      stop(".model must be %in% c('constant', 'AR', 'VAR')")
    } else {
      .model <- .model
    }
    
    .dist.models <- c('mvnorm', 'manig', 'magh')
    if (.dist.model %in% .dist.models) {
      .dist.model <- .dist.model
    } else {
      stop(".dist.model must %in% c('mvnorm', 'manig', 'magh').")
    }
    
    spec <- gogarchspec(
      variance.model = list(
        model = 'gjrGARCH', garchOrder = c(1, 1),    # Univariate Garch 2012 powerpoint.pdf
        submodel = NULL, external.regressors = NULL, #   compares the garchOrder and 
        variance.targeting = FALSE),                 #   concludes garch(1,1) is the best fit.
      mean.model = list(
        model = .model, robust = FALSE), 
      distribution.model = .dist.model)
    
    fit <- gogarchfit(spec, mbase, solver = 'hybrid', cluster = cl)
    cat('step 1/2 gogarchfit done!\n')
    
    if (.roll == TRUE) {
      mod = gogarchroll(spec, data = mbase, solver = .solver, cluster = cl)
      cat('step 2/1 gogarchroll done!\n')
      
    } else {
      fc <- gogarchforecast(fit, n.ahead = .ahead, cluster = cl)
      cat('step 2/2 gogarchforecast done!\n')
    }
    
  } else if (.mv.model == 'copula-GARCH') {
    ...
  } else {
    stop("Kindly set .mv.model as 'dcc', 'go-GARCH' or 'copula-GARCH'.")
  }
  
  if (.roll == TRUE) {
    return(report(mod, type = 'fpm'))
    
  } else {
      
    res = fitted(fc)
    colnames(res) = names(mbase)
    latestPrice = tail(mbase, 1)
    
    #rownames(res) <- as.character(forDate)
    latestPrice <- xts(latestPrice)
    #res <- as.xts(res)
    
    tmp = list(latestPrice = latestPrice, forecastPrice = res, 
               fit = fit, forecast = fc, AIC = infocriteria(fit))
    return(tmp)
  }
  
  
})


