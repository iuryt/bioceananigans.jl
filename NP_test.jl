using Oceananigans
using Oceananigans.Units

# define the size and max depth of the simulation
const sponge = 20
const Ny = 100
const Nz = 48 # number of points in z
const H = 1000 # maximum depth

# create the grid of the model
grid = RectilinearGrid(CPU(),
    size=(Ny+2sponge, Nz),
    halo=(3,3),
    y=(-(Ny/2 + sponge)kilometers, (Ny/2 + sponge)kilometers), 
    z=(H * cos.(LinRange(π/2,0,Nz+1)) .- H)meters,
    topology=(Flat, Bounded, Bounded)
)


coriolis = FPlane(latitude=60)

@inline νh(x,y,z,t) = ifelse((y>-(Ny/2)kilometers)&(y<(Ny/2)kilometers), 1, 100)
horizontal_closure = HorizontalScalarDiffusivity(ν=νh, κ=νh)

@inline νz(x,y,z,t) = ifelse((y>-(Ny/2)kilometers)&(y<(Ny/2)kilometers), 1e-5, 1e-3)
vertical_closure = ScalarDiffusivity(ν=νz, κ=νz)


#--------------- NP Model

# constants for the NP model
const μ₀ = 1/day   # surface growth rate
const m = 0.015/day # mortality rate due to virus and zooplankton grazing
const Kw = 0.059 # meter^-1
const Kc = 0.041 # m^2 mg^-1
const kn = 0.75
const kr = 0.5
const α = 0.0538/day
const L0 = 100


# create the mld field that will be updated at every timestep
h = Field{Center, Center, Nothing}(grid) 
light = Field{Center, Center, Center}(grid)

# evolution of the available light at the surface
@inline L(z) = L0*exp.(z*Kw)
# light profile
@inline light_growth(z) = μ₀ * (L(z)*α)/sqrt(μ₀^2 + (L(z)*α)^2)

# nitrate and ammonium limiting
@inline N_lim(N, Nr) = (N/(N+kn)) * (kr/(Nr+kr))
@inline Nr_lim(Nr) =  (Nr/(Nr+kr))

# functions for the NP model
@inline P_forcing(light, P, N, Nr)  =   light * (N_lim(N, Nr) + Nr_lim(Nr)) * P - m * P^2
@inline N_forcing(light, P, N, Nr)  = - light * N_lim(N, Nr) * P
@inline Nr_forcing(light, P, N, Nr) = - light * Nr_lim(Nr) * P + m * P^2

# functions for the NP model
@inline P_forcing(i, j, k, grid, clock, fields, p)  = @inbounds P_forcing(p.light[i, j, k], fields.P[i, j, k], fields.N[i, j, k], fields.Nr[i, j, k])
@inline N_forcing(i, j, k, grid, clock, fields, p)  = @inbounds N_forcing(p.light[i, j, k], fields.P[i, j, k], fields.N[i, j, k], fields.Nr[i, j, k])
@inline Nr_forcing(i, j, k, grid, clock, fields, p) = @inbounds Nr_forcing(p.light[i, j, k], fields.P[i, j, k], fields.N[i, j, k], fields.Nr[i, j, k])

# using the functions to determine the forcing
P_dynamics = Forcing(P_forcing, discrete_form=true, parameters=(; light))
N_dynamics = Forcing(N_forcing, discrete_form=true, parameters=(; light))
Nr_dynamics = Forcing(Nr_forcing, discrete_form=true, parameters=(; light))

#--------------- Instantiate Model

# create the model
model = NonhydrostaticModel(grid = grid,
                            advection = WENO5(),
                            timestepper = :RungeKutta3,
                            coriolis = coriolis,
                            closure=(horizontal_closure, vertical_closure),
                            tracers = (:b, :P, :N, :Nr),
                            buoyancy = BuoyancyTracer(),
                            forcing = (P=P_dynamics, N=N_dynamics, Nr=Nr_dynamics))



#--------------- Initial Conditions

const cz = -200 # mld
const g = 9.82 # gravity
const ρₒ = 1026 # reference density


# background density profile based on Argo data
@inline bg(z) = 0.25*tanh(0.0027*(-653.3-z))-6.8*z/1e5+1027.56

# decay function for fronts
@inline decay(z) = (tanh((z+500)/300)+1)/2

@inline front(x, y, z, cy) = tanh((y-cy)/12kilometers)
@inline D(x, y, z) = bg(z) + 0.8*decay(z)*front(x, y, z, 0)/4
@inline B(x, y, z) = -(g/ρₒ)*D(x, y, z)

# initial phytoplankton profile
@inline P(x, y, z) = ifelse(z>cz, 0.4, 0)

# setting the initial conditions
set!(model; b=B, P=P, N=13, Nr=0)


#--------------- Simulation

# # create a simulation
simulation = Simulation(model, Δt = 1minutes, stop_time = 20days)

wizard = TimeStepWizard(cfl=1.0, max_change=1.1, max_Δt=1hour)
simulation.callbacks[:wizard] = Callback(wizard, IterationInterval(10))

include("src/compute_mixed_layer_depth.jl")
const Δb=(g/ρₒ) * 0.03
compute_mixed_layer_depth!(simulation) = compute_mixed_layer_depth!(h, simulation.model.tracers.b, Δb)
# add the function to the callbacks of the simulation
simulation.callbacks[:compute_mld] = Callback(compute_mixed_layer_depth!)

include("src/compute_light.jl")
compute_light!(simulation) = compute_light!(light, h, simulation.model.tracers.P, light_growth)
# add the function to the callbacks of the simulation
simulation.callbacks[:compute_light] = Callback(compute_light!)

# zero_tracer(sim) = map!(c -> ifelse(c < 0, 0.0, c), parent(sim.model.tracers.N), parent(sim.model.tracers.N))
zero_N(sim) = parent(sim.model.tracers.N) .= max.(0, parent(sim.model.tracers.N))
simulation.callbacks[:zero_N] = Callback(zero_N)

# merge light and h to the outputs
outputs = merge(model.velocities, model.tracers, (; light, h)) # make a NamedTuple with all outputs

# writing the output
simulation.output_writers[:fields] =
    NetCDFOutputWriter(model, outputs, filepath = "data/NP_output.nc",
                     schedule=TimeInterval(3hours))

using Printf

function print_progress(simulation)
    b, P, N, Nr = simulation.model.tracers

    # Print a progress message
    msg = @sprintf("i: %04d, t: %s, Δt: %s, P_max = %.1e, N_min = %.1e, Nr_max = %.1e, wall time: %s\n",
                   iteration(simulation),
                   prettytime(time(simulation)),
                   prettytime(simulation.Δt),
                   maximum(P), minimum(N), maximum(Nr),
                   prettytime(simulation.run_wall_time))
    
    @info msg

    return nothing
end

simulation.callbacks[:progress] = Callback(print_progress, TimeInterval(1hour))

# run the simulation
run!(simulation)