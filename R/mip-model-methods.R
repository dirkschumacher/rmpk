mip_model_impl_add_variable <- function(name, ..., type = "continuous", lb = -Inf, ub = Inf) {
  stopifnot(
    length(type) == 1L, length(lb) == 1L, length(ub) == 1L,
    length(name) == 1L, is.character(name), !is.na(name)
  )
  type <- match.arg(type, c("continuous", "integer", "binary"))
  var_names <- generate_variable_names(...)
  rlp_vars <- lapply(var_names$var_names, function(var_name) {
    var_idx <- if (type == "continuous") {
      moi_add_variable(private$solver)
    } else {
      set <- if (type == "integer") integer_set else zero_one_set
      moi_add_constrained_variable(private$solver, set)[[1]]
    }
    var_ref <- RMPK_variable(var_idx@value, self)
    if (is.finite(lb) && !is.finite(ub)) {
      moi_add_constraint(private$solver, single_variable(var_ref), greater_than_set(lb))
    } else if (!is.finite(lb) && is.finite(ub)) {
      moi_add_constraint(private$solver, single_variable(var_ref), less_than_set(ub))
    } else if (is.finite(lb) && is.finite(ub)) {
      moi_add_constraint(private$solver, single_variable(var_ref), interval_set(lb, ub))
    }
    MOI::scalar_affine_term(coefficient = 1, var_ref)
  })
  names(rlp_vars) <- var_names$var_names
  variable <- if (var_names$is_indexed_var) {
    variable_map <- fastmap::fastmap()
    variable_map$mset(.list = rlp_vars)
    new("RMPK_variable_list",
      variables_map = variable_map,
      arity = var_names$arity,
      index_types = var_names$index_types
    )
  } else {
    rlp_vars[[1L]]
  }
  private$register_variable(name, variable)
  variable
}

mip_model_impl_set_objective <- function(obj_variables, sense = "min") {
  sense <- match.arg(sense, c("max", "min"))
  moi_set(private$solver, MOI::objective_function, obj_variables)
  moi_sense <- if (sense == "max") MOI::MAX_SENSE else MOI::MIN_SENSE
  moi_set(private$solver, MOI::objective_sense, moi_sense)
  invisible()
}

mip_model_impl_set_bounds <- function(expr, ..., lb = NULL, ub = NULL) {
  expr <- rlang::enquo(expr)

  eval_per_quantifier(function(local_envir) {
    var <- rlang::eval_bare(rlang::get_expr(expr), env = local_envir)
    var <- if (inherits(var, "MOI_scalar_affine_term")) var@variable else var
    if (!is.null(lb)) {
      moi_add_constraint(private$solver, single_variable(var), greater_than_set(lb))
    }
    if (!is.null(ub)) {
      moi_add_constraint(private$solver, single_variable(var), less_than_set(ub))
    }
  }, .base_envir = rlang::get_env(expr), ...)

  invisible()
}

mip_model_impl_add_constraint <- function(.expr, ..., .in_set = NULL) {
  # either we have an equation in expr or in_set != NULL
  expr <- rlang::enquo(.expr)
  eval_fun <- if (!is.null(.in_set)) {
    function(local_envir) {
      private$add_set_constraint(
        func = rlang::eval_tidy(expr, env = local_envir),
        set = .in_set
      )
    }
  } else {
    eq <- split_equation(rlang::get_expr(expr))
    function(local_envir) {
      private$add_row(local_envir, eq)
    }
  }
  eval_per_quantifier(eval_fun, .base_envir = rlang::get_env(expr), ...)

  invisible()
}

eval_per_quantifier <- function(.eval_fun, .base_envir, ...) {
  quantifiers <- construct_quantifiers(...)
  quantifier_var_names <- names(quantifiers)
  no_quantifiers <- nrow(quantifiers) == 0L || ncol(quantifiers) == 0L
  all_quantifiers_filtered_out <- ncol(quantifiers) > 0L &&
    nrow(quantifiers) == 0L
  if (all_quantifiers_filtered_out) {
    return()
  }
  if (no_quantifiers) {
    local_envir <- new.env(parent = .base_envir)
    .eval_fun(local_envir)
  } else {
    for (i in seq_len(nrow(quantifiers))) {
      local_envir <- new.env(parent = .base_envir)
      vars <- quantifiers[i, , drop = TRUE]
      for (j in seq_len(ncol(quantifiers))) {
        local_envir[[quantifier_var_names[j]]] <- vars[[j]]
      }
      .eval_fun(local_envir)
    }
  }
}

mip_model_impl_optimize <- function() {
  moi_optimize(private$solver)
  invisible()
}

mip_model_impl_termination_status <- function() {
  moi_get(private$solver, MOI::termination_status)
}

mip_model_impl_termination_message <- function() {
  moi_get(private$solver, MOI::termination_solver_message)
}

get_var_value <- function(type, solver) {
  get_var <- function(x) {
    UseMethod("get_var")
  }
  get_var.MOI_scalar_affine_term <- function(x) {
    x@variable
  }
  get_var.MOI_single_variable <- function(x) {
    x@variable
  }
  get_var.RMPK_variable <- identity
  function(variable) {
    moi_get(solver, type, get_var(variable))
  }
}

mip_model_impl_get_value <- function(variable_selector) {
  extract_solver_variable_value(
    private,
    rlang::enquo(variable_selector),
    get_var_value(MOI::variable_primal, private$solver)
  )
}

mip_model_impl_get_variable_dual <- function(variable_selector) {
  extract_solver_variable_value(
    private,
    rlang::enquo(variable_selector),
    get_var_value(MOI::variable_dual, private$solver)
  )
}

extract_solver_variable_value <- function(private, variable_expr,
                                          get_value_fun) {
  variable_expr_rl <- variable_expr
  variable_expr <- rlang::get_expr(variable_expr)
  envir <- rlang::get_env(variable_expr_rl)
  is_index_call <- is.call(variable_expr) && variable_expr[[1L]] == "["
  if (is_index_call) {
    var_name <- as.character(variable_expr[[2L]])
    indexes <- vapply(variable_expr[3:length(variable_expr)], function(x) {
      as.character(x)
    }, character(1L))
    variable_container <- envir[[var_name]]
    if (length(indexes) != variable_container@arity) {
      stop(var_name, " is a variable with ", variable_container@arity, " indexes. ",
        "But you used the variable with ", length(indexes), " indexes.",
        call. = FALSE
      )
    }
    variables_list <- variable_container@variables_map$as_list()
    relevant_keys <- names(variables_list)
    values <- vapply(variables_list, function(x) {
      get_value_fun(x)
    }, numeric(1L))
    splitted_keys <- strsplit(relevant_keys, "/", fixed = TRUE)
    return_val <- t(as.data.frame(splitted_keys, stringsAsFactors = FALSE))
    return_val <- as.data.frame(return_val, stringsAsFactors = FALSE)
    rownames(return_val) <- NULL
    return_val[["value"]] <- values
    return_val[["name"]] <- var_name
    colnames(return_val) <- c(indexes, "value", "name")
    return_val <- return_val[, c("name", indexes, "value"), drop = FALSE]
    # set the right types for the index columns
    for (i in seq_along(indexes)) {
      type <- variable_container@index_types[[i]]
      if (type == "character") {
        return_val[[1 + i]] <- as.character(return_val[[1 + i]])
      }
      if (type == "integer") {
        return_val[[1 + i]] <- as.integer(return_val[[1 + i]])
      }
    }
    return(return_val)
  } else if (is.symbol(variable_expr)) {
    variable <- rlang::eval_tidy(variable_expr_rl)
    return(get_value_fun(variable@variable_index))
  }
  stop("Wrong expression", call. = FALSE)
}

mip_model_impl_get_row_duals <- function() {
  rows <- private$row_indexes
  values <- vapply(rows, function(i) {
    moi_get(private$solver, MOI::constraint_dual(), RMPK_constraint(i, self))
  }, numeric(1L))
  data.frame(
    row_index = rows,
    value = values
  )
}

mip_model_impl_objective_value <- function() {
  moi_get(private$solver, objective_value())
}

generate_variable_names <- function(...) {
  quantifiers <- construct_quantifiers(...)
  if (ncol(quantifiers) == 0) {
    return(list(
      var_names = "x",
      arity = 0L,
      is_indexed_var = FALSE
    ))
  }
  index_list_data_type <- vapply(quantifiers, function(x) {
    if (is.character(x)) {
      "character"
    } else if (is.integer(x)) {
      "integer"
    } else {
      stop("Only integer and character quantifiers are supported. ",
        "One of your quantifiers has the classes: ",
        paste0(class(x), collapse = ","),
        call. = FALSE
      )
    }
  }, character(1L))
  names(index_list_data_type) <- NULL

  names <- as.character(apply(quantifiers, 1L, function(row) {
    # TODO: check if any value in row has "/"
    paste0(row, collapse = "/")
  }))

  list(
    var_names = names,
    arity = ncol(quantifiers),
    index_types = index_list_data_type,
    is_indexed_var = TRUE
  )
}

split_equation <- function(expr) {
  stopifnot(is.call(expr))
  operator <- as.character(expr[[1L]])
  stopifnot(operator %in% c("<=", ">=", "=="))
  list(
    operator = operator,
    lhs = expr[[2L]],
    rhs = expr[[3L]]
  )
}
