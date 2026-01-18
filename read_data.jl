using Pkg, JuMP, Gurobi, HDF5, CSV, XLSX, DataFrames

# FOCUS ON LINE 53
###############################################################################
# 2) Define Your Sets and Parameters (Replace placeholders with real data)
path = pwd() * "\\"
bus_characteristics = path * "Bus characteristics - loc.xlsx"
data_folder = path * "28_buses\\"
data_l_jkeD = data_folder * "l_jkeD.h5"
data_b_kie  = data_folder * "b_kie.csv"


# 2) Read the entire workbook
wb = XLSX.readxlsx(bus_characteristics)
sheet1 = wb["Brussels"]
#for s_name in sheet_names
#    sheet = workbook[s_name]
#    println("Now reading sheet: ", s_name)
sheet2= wb["Bus 53 and 46"]
sheet3= wb["Events only"]
PeakPower = wb["Peak Power"]
Parameters = wb["Parameter"]
Preparameters = wb["Pre-Parameter"]
Trips = wb["Trips"]

###############################################################################
#Building dictionaries/ arrays
ndepots = 3
nBuses = 28
nevents= 410 #previously 406
ntrips = 232
npow = 10 #asked Penelope how did she get this information

J = 1:ndepots       # Depots
K = 1:nBuses   # Electric buses
E = 1:nevents   # Events/time slots #Dependent on how many times it will be updated
N_j = [1:3,1:2,1:2] # Charger indices at each depot  #Don't know yet how to approach this problem
I = 1:ntrips        # Set of trips
L = 1:npow                 # Power levels(MW)

###############################################################################
l_jke = h5read(data_l_jkeD, "l_jkeD")
l_jke.size
println(l_jke[27,320,3])

total = 0
for e in 13:37
    sum1 = 0
    for k in K, j in J
        sum1 += l_jke[k,e,j]
    end
println("Number of buses at depot during event $e: ", sum1)
total += sum1
end
println("total number of buses at depot from 6-7: ", total)

#Average energy consumption for trip i (kWh/km)
b_kie= zeros(Int,ntrips,nevents)
gamma       = Array{Float64}(undef, ntrips, 1)    # γᵢ consommation (kWh/km), colonne
t_i         = Array{Float64}(undef, ntrips, 1)      # distance du voyage i, colonne
bus_assigned = Array{Int}(undef, ntrips, 1)      # bus assigné, colonne
events_str = Vector{String}(undef, ntrips)
for i in 1:ntrips
    row = i+1 #so when i=1,row=7
    # 29th = AC
    gamma[i] = Float64(Trips[row,8])
    bus_assigned[i] = Int(Trips[row,4])
    t_i[i]= round(Float64(Trips[row,15]), digits = 2)
    events_str[i] = String(Trips[row,9])
    covered_events = parse.(Int, strip.(split(events_str[i], ",")))#parse.(Int, strip.(split(raw_events))
    for e in covered_events
       b_kie[i,e] = 1.0
    end
end 

println(gamma)
println(t_i)
###############################################################################

bus_assigned_mat = zeros(Float16, ntrips, nBuses)
for i in 1:ntrips
    # Convert from 501..528 to 1..28
    bus_num = Int(bus_assigned[i]) - 500  
    bus_assigned_mat[i, bus_num] = 1
end

#df_b_kie = DataFrame(b_kie,:auto) #convert matrix to a dataframe
#CSV.write("b_kie.csv", df_b_kie) #write the dataframe to a csv file

#Read the CSV File 
kie = CSV.read(data_b_kie, DataFrame)
b_ie = Matrix(kie)

b_kie = zeros(Int, nBuses, ntrips, nevents)
for i in 1:ntrips
    for k in 1:nBuses
        if bus_assigned_mat[i,k] == 1 
            for e in 1:nevents
                if b_ie[i,e] ==1
                b_kie[k, i, e] = 1
                end
            end
        end
    end
end

b_kie.size
println(b_kie[1,172,295])

# CHECK MISTAKE HERE AND EGK
#Time parameters #don't know where to find it 
T_E =Array{Float64}(undef, nevents,1)  #minute at which event e occurs and timeslot e starts
deltaT_E =Array{Int}(undef, nevents,1)   #duration of event e
#Price Parameters
rho_plus  = Array{Float64}(undef, nevents,1)   # ρₑ⁺ purchasing price (€/kWh)
rho_minus = Array{Float64}(undef, nevents,1)  # ρₑ⁻ selling price  (€/kWh)
Q = Array{Float64}(undef,ndepots,nevents)  #only depot 0 is generating electricity 
theta = Array{Int}(undef, nevents,1) 
V = Array{Float64}(undef, nevents,1)  #minimum number of time slots required 
M_j = Array{Int16}(undef,ndepots,nevents) #bus arrival or bus departure

for i in 1:nevents
    row = i+1
    T_E[i] = Float64(sheet3[row,2])
    deltaT_E[i] = round(Int, Float64(sheet3[row,5])*24*60)
    rho_plus[i] = Float64(sheet3[row,13])
    rho_minus[i] = Float64(sheet3[row,14])
    Q[1,i] = Float64(sheet3[row,17]) #but only depot 
    Q[2,i] = 0
    Q[3,i] = 0
    theta[i] = Int(sheet3[row,16])#Pv panels at depot j generates electricity during time e
    V[i] = Float64(sheet3[row,7])
    M_j[1,i] = Int(sheet3[row,8])
    M_j[2,i] = Int(sheet3[row,9])
    M_j[3,i] = Int(sheet3[row,10])
end
print(deltaT_E)
print(Q)

###############################################################################
# Determine the maximum number of chargers among all depots
max_chargers = maximum(length.(N_j))  # should be 24 in your case

# Create 2D arrays (matrices) for each parameter, with size (ndepots, max_chargers)
alpha    = Array{Float64}(undef, ndepots, max_chargers)
eta_char = Array{Float64}(undef, ndepots, max_chargers)
eta_dis  = Array{Float64}(undef, ndepots, max_chargers)
beta     = Array{Float64}(undef, ndepots, max_chargers)

counter = 0

for i in 1:ndepots
    num_chargers = length(N_j[i])
    # Fill the entries for the chargers that exist for depot i
    for j in 1:num_chargers
        alpha[i, j]    = Float64(sheet1[38 + counter, 4])
        # eta_char[i, j] = 0.82 # sensitivity analysis
        # eta_dis[i, j]  = 0.82 # sensitivity analysis
        eta_char[i, j] = Float64(sheet1[38 + counter, 3])
        eta_dis[i, j]  = Float64(sheet1[38 + counter, 5])
        beta[i, j]     = Float64(sheet1[38 + counter, 6])
        counter += 1
    end
    # For depots with fewer chargers than max_chargers, fill the remaining columns with NaN (or any default value)
    for j in (num_chargers + 1):max_chargers
        alpha[i, j]    = NaN
        eta_char[i, j] = NaN
        eta_dis[i, j]  = NaN
        beta[i, j]     = NaN
    end
end

println(length(N_j[1]))
println(beta)

###############################################################################
#Battery and bus parameters
#undef = not to fill the array with any default value. 
E_min    = Array{Float64}(undef, nBuses,1)    # min SOC
E_max    = Array{Float64}(undef, nBuses,1)    # max SOC
E0       = Array{Float64}(undef, nBuses,1)     # initial SOC
Eend     = Array{Float64}(undef, nBuses,1)  # min SOC at end of day
C_bat = Array{Float64}(undef, nBuses,1)  # Battery capacity
N_cyc = Array{Float64}(undef, nBuses,1)  # Max number of cycles a firm can perform
DoD = Array{Float64}(undef, nBuses,1)  # Depth of discharge
R = Array{Float64}(undef, nBuses,1)  # Replacement cost of the battery 
f = Array{Float64}(undef, nBuses,1)  # Fixed cost of the battery
e_gk =Array{Int}(undef, nBuses,1) # index of time slot at which bus k arrives after finishing all trips
for i in 1:nBuses
    row = i +6  # e.g., i=1 => row=2, i=2 => row=3, etc.
    row2 = i+2
    C_bat[i]= Float64(sheet1[row, 2])  # total capacity
    E_min[i]= Float64(sheet1[row, 3])  # min SOC
    E_max[i] = Float64(sheet1[row, 4])  # max SOC
    E0[i] = Float64(sheet1[row, 5])  # initial SOC
    Eend[i] = Float64(sheet1[row, 6])  # end-of-day SOC
    N_cyc[i] = Float64(sheet1[row, 7])  # # cycles
    DoD[i] = Float64(sheet1[row, 8])  # depth of discharge
    R[i] = Float64(sheet1[row, 9])  # replacement cost
    f[i]= Float64(sheet1[row, 11])  # fixed cost
    e_gk[i] = Int(sheet1[row,13])  # index of time slot at which bus k arrives after finishing all trips
end
print(e_gk[1])
println(C_bat)
###############################################################################
tau_m = 5 #Minimum charging time required to increase battery lifespan 5MIN 
Hj = [1228,0,0] #Total Storage cap of ESS [614,0,0] sensitivity analysis
Ef = last(nevents)
SOC_min = [0.2,0.2,0.2] #Minimum SOC of ESS
e_s= 408 #HERE NO CORRECT 
#l_jke= Vector{Float64}(undef,ntrips) #bus k is at depot j during E
println(Ef)

#Power Parameters
U_pow = Array{Float64}(undef,npow,1)  # Peak power levels
U_max = 1000                      # Max total power
U_price =Array{Float64}(undef,npow,1) #price power level
for i in 1:npow
    row = i+1
    U_pow[i] = Float64(PeakPower[row,1])
    U_price[i] = Float64(PeakPower[row,2])
end

#=function parse_events(str::String)
    # If there's nothing to parse, return empty Int array.
    if str == ""
        return Int[]
    end
    # Otherwise split on commas and parse to Int.
    # keepempty=false ensures no empty tokens if there are extra commas.
    parts = split(str, ',', keepempty=false)
    return parse.(Int, strip.(parts))
end=#

#=l_jkeD0 = zeros(Float64,nBuses,nevents)
l_jkeD1 = zeros(Float64,nBuses,nevents)
l_jkeD2 = zeros(Float64,nBuses,nevents)
l_jke = zeros(Float64,nBuses,nevents)
D0 = Vector{String}(undef,nBuses)
D1 = Vector{String}(undef,nBuses)
D2 = Vector{String}(undef, nBuses)
#rawD0 =  Vector{String}(undef, nBuses)
#k is like index 1 in the bus'orders
for i in 1:nBuses
    row = i + 2
    
    # 1) Convert missing to "", otherwise leave as string
    rawD0 = coalesce(Parameters[row, 3], "")
    rawD1 = coalesce(Parameters[row, 4], "")
    rawD2 = coalesce(Parameters[row, 5], "")
    # 2) Store raw strings if needed
    D0[i] = rawD0
    D1[i] = rawD1
    D2[i] = rawD2
    # 3) Parse integer events
    D0_covered_events = parse_events(rawD0)
    D1_covered_events = parse_events(rawD1)
    D2_covered_events = parse_events(rawD2)
    # Continue with your logic, e.g., using D0_covered_events, etc.
    for e in D0_covered_events
        l_jkeD0[i,e] = 1.0
    end

    for e in D1_covered_events
         l_jkeD1[i,e] = 1.0
    end
    for e in D2_covered_events
        l_jkeD2[i,e] = 1.0
    end
end=#

#l_jkeD = zeros(Float64,ndepots,nBuses,nevents)
#l_jkeD = cat(l_jkeD0, l_jkeD1, l_jkeD2, dims=3)

#h5write("l_jkeD.h5", "l_jkeD", l_jkeD)
#later you can read it through 
#read_array =h5read("l_jkeD.h5", "l_jkeD")