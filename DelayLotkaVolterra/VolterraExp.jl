cd(@__DIR__)
using Pkg; Pkg.activate("."); Pkg.instantiate()

# Single experiment, move to ensemble further on
# Some good parameter values are stored as comments right now
# because this is really good practice

using OrdinaryDiffEq
using ModelingToolkit
using DataDrivenDiffEq
using Flux, Tracker
using LinearAlgebra
using DiffEqFlux
using Plots
gr()



function lotka(du, u, p, t)
    α, β, γ, δ = p
    du[1] = α*u[1] - β*u[2]*u[1]
    du[2] = γ*u[1]*u[2]  - δ*u[2]
end

# Define the experimental parameter
tspan = (0.0f0,3.0f0)
u0 = [0.44249296,4.6280594]
p = Float32[1.3, 0.9, 0.5, 1.8]
prob = ODEProblem(lotka, u0,tspan, p)
solution = solve(prob, Vern7(), saveat = 0.1)

scatter(solution, alpha = 0.25)
plot!(solution, alpha = 0.5)

solution = solve(prob, Vern7(), abstol=1e-12, reltol=1e-12, saveat = 0.1)

# Initial condition and parameter for the Neural ODE
u0_ = Tracker.param(u0)
p_ = param(p)
# Define the neueral network which learns L(x, y, y(t-τ))
# Actually, we do not care about overfitting right now, since we want to
# extract the derivative information without numerical differentiation.
ann = Chain(Dense(2, 32,swish),Dense(32, 32, swish), Dense(32, 2)) |> f32

function dudt_(u::TrackedArray,p,t)
    x, y = u
    Tracker.collect([p[1]*x + ann(u)[1],
        -p[4]*y + ann(u)[2]])
end

function dudt_(u::AbstractArray, p,t)
    x, y = u
    [p[1]*x + Flux.data.(ann(u)[1]),
        -p[4]*y + Flux.data.(ann(u)[2])]
end

# Check the diff_rd functions
isa(dudt_(u0_, p_, 0.0f0), TrackedArray)
isa(dudt_(u0, p, 0.0f0), Array)

prob_ = ODEProblem(dudt_,u0_, tspan, p_)
s = diffeq_rd(p_, prob_, Tsit5(), saveat = solution.t)

plot(solution)
plot!(solution.t, Flux.data.(s)')

function predict_rd()
    diffeq_rd(p_, prob_, Vern7(), saveat = solution.t, abstol=1e-6, reltol=1e-6)
end

function predict_rd(sol)
    diffeq_rd(p_, prob_, u0 = param(sol[:,1]), Vern7(),
              abstol=1e-6, reltol=1e-6,
              saveat = sol.t)
end

# No regularisation right now
loss_rd() = sum(abs2, solution[:,:] .- predict_rd()[:,:]) # + 1e-5*sum(sum.(abs, params(ann)))
loss_rd()

# AdamW forgets, which might be nice since the nn changes topology over time
opt = ADAMW()

const losses = []
callback() = begin
    push!(losses, Flux.data(loss_rd()))
    if length(losses)%50==0
        println(losses[end])
    end
end

# Train the neural DDE
Juno.@progress for i in 1:3000 - length(losses)
    Flux.train!(loss_rd, params(ann), [()], opt, cb = callback)
end

# Plot the data and the approximation
plot(solution.t, Flux.data.(predict_rd(solution)'))
plot!(solution.t, solution[:,:]')
loss_rd()

# Collect the state trajectory and the derivatives
X = solution[:,:]
DX = solution(solution.t, Val{1})[:,:] #- [p[1]*(X[1,:])';  -p[4]*(X[2,:])']
L̃ = Flux.data(ann(X))
_sol = predict_rd()
DX_ = Flux.data.(_sol(solution.t, Val{1})[:,:])
# The learned derivatives
plot(DX')
plot!(DX_')

L = [-p[2]*(X[1,:].*X[2,:])';p[3]*(X[1,:].*X[2,:])']
X̂ = rand(2, 200)
L̂ = Flux.data(ann(X̂))
scatter(L̂')
plot(L')
plot!(L̃')

# Create a Basis
@variables u[1:2]
# Lots of polynomials
polys = []
for i ∈ 1:3
    push!(polys, u[1]^i)
    push!(polys, u[2]^i)
    for j ∈ i:3
        if i == j
            push!(polys, (u[1]^i)*(u[2]^j))
        end
    end
end

# And some other stuff
h = [cos(u[1]); sin(u[1]); 1u[1]^0; polys...]

basis = Basis(h, u)
Ψ = SInDy(X[:,:], DX[:,:], basis, ϵ = 1e-1) # Fail
println(Ψ.basis)
Ψ = SInDy(X[:, :], L[:, :], basis, ϵ = 1e-1) # Suceed
println(Ψ.basis)
Ψ = SInDy(X[:, :], L̃[:, :], basis, ϵ = 1e-1) # Fail
println(Ψ.basis)

# Works most of the time
θ = hcat([basis(xi, p = []) for xi in eachcol(X)]...)
Ξ = DataDrivenDiffEq.STRridge(θ', L̃', ϵ = 3e-1, maxiter = 10000)
Ψ = Basis(simplify_constants.(Ξ'*basis.basis), u)
println(Ψ.basis)

function approx(du, u, p, t)
    #z = [u..., h(p, t-2.0f0)[2]]
    α, β, γ, δ = p
    # Known Dynamics
    du[1] = α*u[1]
    du[2] = -δ*u[2]
    # Add SInDy Term
    du .+= Ψ(u)
end

NNsolution = Flux.data.(predict_rd()[:,:])

tspan = (0.0f0, 20.0f0)
a_prob = ODEProblem(approx, u0, tspan, p)
a_solution = solve(a_prob, Vern7(), saveat = 0.1f0, abstol=1e-6, reltol=1e-6)

prob_true2 = ODEProblem(lotka, u0,tspan, p)
solution_long = solve(prob_true, Vern7(), abstol=1e-8, reltol=1e-8, saveat = 0.1)

using JLD2
@save "knowledge_enhanced_NN.jld2" solution Ψ a_solution NNsolution ann solution_long Z L l1 l2
@load "knowledge_enhanced_NN.jld2" solution Ψ a_solution NNsolution ann solution_long Z L l1 l2

p1 = plot(abs.(solution .- NNsolution)' .+ eps(Float32),
          lw = 3, yaxis = :log, title = "Timeseries of UODE Error",
          color = [:blue :green],
          label = ["x(t)" "y(t)"],
          legend = :bottomright)

# Plot L₂
p2 = plot(Z[1,:], Z[2,:], L[2,:], lw = 3,
     title = "Neural Network Fit of U2(t)", color = :blue,
     label = "Neural Network", xaxis = "x", yaxis="y",
     legend = :bottomright)
plot!(Z[1,:], Z[2,:], l2, lw = 3, label = "True Missing Term", color=:green)

p3 = scatter(solution, color = [:red :orange], label = ["x data" "y data"], title = "Extrapolated Fit From Short Training Data")
plot!(p3,solution_long, color = [:red :orange], label = ["True x(t)" "True y(t)"])
plot!(p3,a_solution, linestyle = :dash , color = [:blue :green], label = ["Estimated x(t)" "Estimated y(t)"])

l = @layout [grid(1,2)
             grid(1,1)]
plot(p1,p2,p3,layout = l)

savefig("sindy_extrapolation.pdf")