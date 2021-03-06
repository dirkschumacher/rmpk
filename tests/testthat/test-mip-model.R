library(ROI.plugin.glpk)
test_that("building a simple model", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10, j = 1:10)
  model$set_objective(sum_expr(x[i, j], i = 1:10, j = 1:10))
  model$add_constraint(sum_expr(x[i, j], j = 1:i) <= 10, i = 1:10)
  expect_equal(as.numeric(as.matrix(solver@ptr$objective_coefficients())), rep.int(1, 100))
  mat <- solver@ptr$constraint_matrix()
  expect_equal(nrow(mat), 10)
})

test_that("correct index types are used in get_variable_value", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10, j = as.character(1:10), k = c("a", "b"))
  model$optimize()
  ret <- model$get_variable_value(x[i, j, k])
  expect_true(is.character(ret$name))
  expect_true(is.character(ret$j))
  expect_true(is.character(ret$k))
  expect_true(is.integer(ret$i))
})

test_that("you can only use characters and integers as indexes", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  expect_error(
    model$add_variable("x", i = as.factor(1:10)),
    regexp = "integer|character"
  )
})

test_that("using not the right number of indeses errors in get_var_value", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10, j = as.character(1:10), k = c("a", "b"))
  expect_error(model$get_variable_value(x[i, j]), "indexes")
})

test_that("A constant objective function is possible", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x")
  expect_silent(model$set_objective(5))
})

test_that("MIPModel prints some information", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x")
  model$add_constraint(x <= 1)
  expect_output(model$print(), "1")
})

test_that("add_variables exposes the variable classes to the env", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:3)
  expect_equal(x[2]@variable@value, 2)
})

test_that("sum_expr works outside of the model context", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:3)
  res <- sum_expr(x[i], i = 1:3) + 10
  expect_true(res@constant == 10)
})

test_that("add_variable supports guards", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  mod <- 2
  even <- function(x) x %% mod == 0
  limit <- 3
  x <- model$add_variable("x", i = 1:10, even(i), i < !!limit)
  var <- x@variables_map$as_list()[[1]]
  expect_equal(x@variables_map$size(), 1)
  expect_equal(var@coefficient, 1)
  expect_equal(var@variable@value, 1)
})

test_that("sum_expr supports guards", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10)
  mod <- 2
  even <- function(x) x %% mod == 0
  limit <- 3
  res <- sum_expr(x[i], i = 1:10, even(i), i < !!limit)
  var <- res
  expect_equal(var@coefficient, 1)
  expect_equal(var@variable@value, 2)
})

test_that("add_constraint supports guards", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  mod <- 2
  even <- function(x) x %% mod == 0
  limit <- 5
  x <- model$add_variable("x", i = 1:10)
  model$add_constraint(x[i] <= 1, i = 1:10, even(i), i < !!limit)
  expect_equal(moi_get(solver, MOI::number_of_constraints), 2)
})

test_that("errors if two variables have the same name", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10)
  expect_error(model$add_variable("x", i = 1:10))
})

test_that("you can retrieve variables from the model", {
  solver <- ROI_optimizer("glpk")
  model <- optimization_model(solver)
  x <- model$add_variable("x", i = 1:10)
  expect_equal(
    x,
    model$get_variable_ref("x")
  )
  expect_error(model$get_variable_ref("test"))
})

test_that("you can use e as an index name", {
  model <- optimization_model(ROI_optimizer("glpk"))
  x <- model$add_variable("x", e = 1:3)
  expect_silent(
    model$add_constraint(x[e] == 1, e = 1:3)
  )
})
