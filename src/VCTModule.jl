module VCTModule

export initializeVCT, resetDatabase, selectTrialSimulations, getDB

using SQLite, DataFrames, LightXML, LazyGrids, Dates, CSV, Tables
include("VCTClasses.jl")
include("VCTDatabase.jl")
include("VCTConfiguration.jl")
include("VCTExtraction.jl")


# I considered doing this with a structure of parameters, but I don't think that will work well here:
#   1. the main purpose would be to make this thread safe, but one machine will not run multiple sims at once most likely
#   2. Even if we did run multiple at once, it would need to be from the same executable file, so all the global variables would be the same for all
#   3. The cost of checking the global scope is absolutely minimal compared to the simulations I'm running, so who cares about

physicell_dir = abspath("PhysiCell")
data_dir = abspath("data")
PHYSICELL_CPP = "/opt/homebrew/bin/g++-13"

function initializeVCT(path_to_physicell::String, path_to_data::String)
    println("----------INITIALIZING----------")
    global physicell_dir = abspath(path_to_physicell)
    global data_dir = abspath(path_to_data)
    initializeDatabase(data_dir * "/vct.db")
end

function getSimulationCmd(simulation::Simulation; setup=true)
    return `$(physicell_dir)/project $(physicell_dir)/config/base_config_$(simulation.base_config_id)/variation_$(simulation.variation_id).xml $(path_to_simulation_folder)`
end

function runSimulation(simulation::Simulation; setup=true)
    println("------------------------------\n----------SETTING UP SIMULATION----------\n------------------------------")
    path_to_simulation_folder = "$(data_dir)/simulations/$(simulation.id)/output"
    if isfile("$(path_to_simulation_folder)/final.xml")
        ran = false
        return ran
    end
    mkpath(path_to_simulation_folder)

    if setup
        loadConfiguration!(simulation)
        # loadIC!(simulation)
        loadCustomCode!(simulation)
    end

    executable_str = "$(physicell_dir)/project_ccid_$(simulation.custom_code_id)" # path to executable
    config_str =  "$(physicell_dir)/config/base_config_$(simulation.base_config_id)/variation_$(simulation.variation_id).xml" # path to config file
    output_str = "-o $(path_to_simulation_folder)" # path to output folder
    flags = ["-o", path_to_simulation_folder]
    if simulation.ic_id != -1
        # simulation.ic_folder = selectRow("folder_name", "ics", "WHERE ic_id=$(simulation.ic_id);")
        append!(flags, ["-i", "$(data_dir)/ics/$(simulation.ic_folder)/cells.csv"]) # if ic file included (id != -1), then include this in the command
    end
    if false
        # for now, no rules file specified as flagged argument
        append!(flags, ["-r", path_to_rules_file])
    end
    cmd = `$executable_str $config_str $flags`
    
    println("\n----------RUNNING SIMULATION----------\n\n$cmd\n")
    run(cmd, wait=true)
    ran = true
    return ran
end

# function loadIC!(simulation::Union{Simulation,Monad,Sampling})
#     if simulation.ic_id==-1 || simulation.ic_id == current_ic_id
#         return 0
#     end
#     if isempty(simulation.ic_folder)
#         simulation.ic_folder = selectRow("folder_name", "ics", "WHERE ic_id=$(simulation.ic_id);")
#     end
#     path_to_folder = "$(data_dir)/ics/$(simulation.ic_folder)/" # source dir needs to end in / or else the dir is copied into target, not the source files
#     global current_ic_id = simulation.ic_id
#     return run(`cp -r $(path_to_folder) $(physicell_dir)/config`) 
# end

function loadCustomCode!(simulation::Union{Simulation,Monad,Sampling})
    if isfile("$(physicell_dir)/project_ccid_$(simulation.custom_code_id)")
        return 0
    end
    if isempty(simulation.custom_code_folder)
        simulation.custom_code_folder = selectRow("folder_name", "custom_codes", "WHERE custom_code_id=$(simulation.custom_code_id);")
    end
    path_to_folder = "$(data_dir)/custom_codes/$(simulation.custom_code_folder)/" # source dir needs to end in / or else the dir is copied into target, not the source files
    run(`cp -r $(path_to_folder)custom_modules/ $(physicell_dir)/custom_modules`)
    run(`cp $(path_to_folder)main.cpp $(physicell_dir)/main.cpp`)
    run(`cp $(path_to_folder)Makefile $(physicell_dir)/Makefile`)

    return cd(()->run(`make CC=$(PHYSICELL_CPP) PROGRAM_NAME=project_ccid_$(simulation.custom_code_id)`), physicell_dir)
end

function deleteSimulation(simulation_ids::Vector{Int})
    DBInterface.execute(db,"DELETE FROM simulations WHERE simulation_id IN ($(join(simulation_ids,",")));")
    for simulation_id in simulation_ids
        rm("$(data_dir)/simulations/$(simulation_id)", force=true, recursive=true)
    end

    if !(DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table' AND name='trials';") |> isempty)
        trial_ids = DBInterface.execute(db, "SELECT trial_id FROM trials;") |> DataFrame |> x -> x.trial_id
        for trial_id in trial_ids
            trial_simulation_ids = selectTrialSimulations(trial_id)
            filter!(x -> !(x in simulation_ids), trial_simulation_ids)
            if isempty(trial_simulation_ids)
                deleteTrial([trial_id])
            else
                recordTrialSimulationIDs(trial_id, trial_simulation_ids)
            end
        end
    end

    return nothing
end

deleteSimulation(simulation_id::Int) = deleteSimulation([simulation_id])

function trialRowToIds(r::String)
    if !contains(r,":")
        return parse(Int,r)
    end
    # otherwise has a colon and need to expand
    s = split(r,":") .|> String .|> x->parse(Int,x)
    return collect(s[1]:s[2])
end

function deleteTrial(trial_ids::Vector{Int})
    DBInterface.execute(getDB(),"DELETE FROM trials WHERE trial_id IN ($(join(trial_ids,",")));")
    for trial_id in trial_ids
        selectTrialSimulations(trial_id) |> deleteSimulation
        run(`rm -rf $(data_dir)/trials/$(trial_id)`)
    end
    return nothing
end

deleteTrial(trial_id::Int) = deleteTrial([trial_id])

function resetDatabase()

    rm("$(data_dir)/simulations", force=true, recursive=true)
    rm("$(data_dir)/monads", force=true, recursive=true)
    rm("$(data_dir)/samplings", force=true, recursive=true)
    rm("$(data_dir)/trials", force=true, recursive=true)

    for base_configs_folder in (readdir("$(data_dir)/base_configs/", sort=false, join=true) |> filter(x->isdir(x)))
        rm("$(base_configs_folder)/variations.db", force=true)
    end
    
    base_config_ids = DBInterface.execute(db, "SELECT base_config_id FROM base_configs;") |> DataFrame |> x->x.base_config_id
    for base_config_id in base_config_ids
        rm("$(physicell_dir)/config/base_config_$(base_config_id)", force=true, recursive=true)
    end

    custom_code_ids = DBInterface.execute(db, "SELECT custom_code_id FROM custom_codes;") |> DataFrame |> x->x.custom_code_id
    for custom_code_id in custom_code_ids
        rm("$(physicell_dir)/project_ccid_$(custom_code_id)", force=true)
    end

    if db.file == ":memory:"
        initializeDatabase()
    else
        rm("$(db.file)", force=true)
        initializeDatabase("$(db.file)")
    end
    return nothing
end

function runMonad!(monad::Monad; use_previous_sims::Bool=false, setup::Bool=true)
    mkpath("$(data_dir)/monads/$(monad.id)")
    n_new_simulations = monad.min_length
    if use_previous_sims
        n_new_simulations -= length(monad.simulation_ids)
    end

    if n_new_simulations <= 0
        return Task[]
    end

    if setup
        # loadIC!(monad)
        loadCustomCode!(monad)
    end
    loadConfiguration!(monad)

    simulation_tasks = Task[]
    for i in 1:n_new_simulations
        simulation = Simulation(monad)
        push!(simulation_tasks, @task runSimulation(simulation, setup=false))
        push!(monad.simulation_ids, simulation.id)
    end

    recordSimulationIDs(monad)

    return simulation_tasks
end

function recordSimulationIDs(monad::Monad)
    path_to_folder = "$(data_dir)/monads/$(monad.id)/"
    mkpath(path_to_folder)
    path_to_csv = "$(path_to_folder)/simulations.csv"
    lines_table = compressSimulationIDs(monad.simulation_ids)
    CSV.write(path_to_csv, lines_table; writeheader=false)
end

function runSampling!(sampling::Sampling; use_previous_sims::Bool=false)
    mkpath("$(data_dir)/samplings/$(sampling.id)")
    total_sims_ran = 0

    loadCustomCode!(sampling)

    simulation_tasks = []
    for variation_id in sampling.variation_ids
        monad = Monad(sampling, variation_id) # instantiate a monad with the variation_id and the simulation ids already found
        append!(simulation_tasks, runMonad!(monad, use_previous_sims=use_previous_sims, setup=false)) # run the monad and add the number of new simulations to the total
    end

    Threads.@threads :static for simulation_task in simulation_tasks
        schedule(simulation_task)
        fetch(simulation_task)
    end

    recordMonadIDs(sampling) # record the monad ids in the sampling
    return total_sims_ran
end

function recordMonadIDs(sampling_id::Int, monad_ids::Array{Int})
    writeMonadIDs("$(data_dir)/samplings/$(sampling_id)", monad_ids)
end

function recordMonadIDs(sampling::Sampling)
    writeMonadIDs("$(data_dir)/samplings/$(sampling.id)", sampling.monad_ids)
end

function writeMonadIDs(path_to_folder::String, monad_ids::Array{Int})
    path_to_csv = "$(path_to_folder)/monads.csv"
    lines_table = compressMonadIDs(monad_ids)
    CSV.write(path_to_csv, lines_table; writeheader=false)

    path_to_size_csv = "$(path_to_folder)/size.csv"
    size_table = [string.(size(monad_ids))...] |> Tables.table
    CSV.write(path_to_size_csv, size_table; writeheader=false)
end

function compressMonadIDs(monad_ids::Array{Int})
    lines = String[]
    monad_ids = vec(monad_ids)
    while !isempty(monad_ids)
        if length(monad_ids) == 1
            next_line = string(monad_ids[1])
            popfirst!(monad_ids)
        else
            I = findfirst(diff(monad_ids) .> 1)
            I = isnothing(I) ? length(monad_ids) : I # if none found, then all the diffs are 1 so we want to take the entire list
            if I > 1
                next_line = "$(monad_ids[1]):$(monad_ids[I])"
                monad_ids = monad_ids[I+1:end]
            else
                next_line = string(monad_ids[1])
                popfirst!(monad_ids)
            end
        end
        push!(lines, next_line)
    end
    return Tables.table(lines)
end

function runVirtualClinicalTrial(patient_ids::Union{Int,Vector{Int}}, variation_ids::Vector{Vector{Int}}, cohort_ids::Union{Int,Vector{Int}}, num_replicates::Int; use_previous_sims::Bool = false, description::String = String[])
    time_started  = now()
    num_patients = length(patient_ids)
    @assert num_patients == length(variation_ids) # make sure each patient has their own variation ids assigned
    simulation_ids = Int[]
    for i in 1:num_patients
        patient_id = patient_ids[i]
        variation_table_name = "patient_variations_$(patient_id)"
        for cohort_id in cohort_ids
            df = DBInterface.execute(db, "SELECT folder_id,path FROM folders WHERE patient_id=$(patient_id) AND cohort_id=$(cohort_id)") |> DataFrame
            path_to_xml = df.path[1]
            copyMakeFolderFiles(df.folder_id[1])
            path_to_xml = selectRow("path","folders","WHERE patient_id=$(patient_id) AND cohort_id=$(cohort_id)") * "config/PhysiCell_settings.xml"
            for variation_id in variation_ids[i]
                monad = Monad(monad_id, num_replicates, Int[], patient_id, variation_id, cohort_id)
                variation_row = selectRow(variation_table_name,"WHERE variation_id=$(variation_id);")
                loadConfiguration(path_to_xml, variation_row, physicell_dir)
                # append!(simulation_ids, runReplicates(patient_id, variation_id, cohort_id, num_replicates; use_previous_sims=use_previous_sims))
                append!(simulation_ids, runMonad!(monad; use_previous_sims=use_previous_sims))
            end
        end
    end
    recordTrialInfo(simulation_ids, time_started, description)
    return nothing
end

function runVirtualClinicalTrial(patient_ids::Int, variation_ids::Vector{Int}, cohort_ids::Union{Int,Vector{Int}}, num_replicates::Int; use_previous_sims::Bool=false, description::String=String[])
    return runVirtualClinicalTrial(patient_ids, [variation_ids], cohort_ids, num_replicates; use_previous_sims=use_previous_sims, description=description)
end

function runVirtualClinicalTrial(patient_ids::Union{Int,Vector{Int}}, cohort_ids::Union{Int,Vector{Int}}, num_replicates::Int; use_previous_sims::Bool=false, description::String=String[])
    variation_ids = [(DBInterface.execute(db, "SELECT variation_id FROM patient_variations_$(patient_id);") |> DataFrame |> x -> Vector(x.variation_id)) for patient_id in patient_ids]
    return runVirtualClinicalTrial(patient_ids, variation_ids, cohort_ids, num_replicates; use_previous_sims=use_previous_sims, description=description)
end

# function addPatient(patient_name::String,path_to_control_folder::String)
#     db = getDB()
#     df = DBInterface.execute(db, "SELECT patient_id FROM folders WHERE path='$(path_to_control_folder)';") |> DataFrame
#     if !isempty(df)
#         println("This folder location is already present. No patient added.")
#         return df.patient_id[1]
#     end
#     patient_id = DBInterface.execute(db, "INSERT INTO patients (patient_name) VALUES('$(patient_name)') RETURNING patient_id;") |> DataFrame |> x->x.patient_id[1]
#     table_name = "patient_variations_$(patient_id)"
#     DBInterface.execute(db, "CREATE TABLE $(table_name) (
#         variation_id INTEGER PRIMARY KEY
#         )
#     ")
#     DBInterface.execute(db, "INSERT INTO $(table_name) (variation_id) VALUES(0);")
#     DBInterface.execute(db, "INSERT INTO folders (patient_id, cohort_id, path) VALUES($(patient_id),$(control_cohort_id),'$(path_to_control_folder)');")
    
#     path_to_xml = path_to_control_folder * "config/PhysiCell_settings.xml"
#     path_to_default_xml = path_to_control_folder * "config/PhysiCell_settings_default.xml"
#     run(`cp $(path_to_xml) $(path_to_default_xml)`)
#     return patient_id
# end

# function addGVAX(patient_id::Int; cd4_multiplier::AbstractFloat=10., cd8_multiplier::AbstractFloat=2.)
#     db = getDB()
#     gvax_cohort_id = DBInterface.execute(db, "SELECT cohort_id FROM cohorts WHERE intervention='gvax';") |> DataFrame |> x->x.cohort_id
#     if isempty(gvax_cohort_id)
#         gvax_cohort_id = DBInterface.execute(db, "INSERT INTO cohorts (intervention) VALUES('gvax') RETURNING cohort_id;") |> DataFrame |> x->x.cohort_id[1]
#     else
#         gvax_cohort_id = gvax_cohort_id[1]
#     end
#     path_to_control_folder = DBInterface.execute(db, "SELECT path FROM folders WHERE patient_id=$(patient_id) AND cohort_id=$(control_cohort_id);") |> DataFrame |> x->x.path[1]
#     path_to_folder = path_to_control_folder[1:end-1] * "_with_gvax/"
#     folder_id = DBInterface.execute(db, "INSERT OR IGNORE INTO folders (patient_id,cohort_id,path) 
#         VALUES
#             ($(patient_id),$(gvax_cohort_id),'$(path_to_folder)')
#         RETURNING folder_id;
#     ")
#     if isempty(folder_id)
#         println("A GVAX folder for this patient has already been created.")
#         return gvax_cohort_id
#     end
#     run(`cp -r $(path_to_control_folder) $(path_to_folder)`)
#     path_to_xml = path_to_folder * "config/PhysiCell_settings.xml"
#     openXML(path_to_xml)
#     multiplyField(["user_parameters","number_of_PD-1hi_CD4_Tcell"],cd4_multiplier)
#     multiplyField(["user_parameters","number_of_PD-1lo_CD4_Tcell"],cd4_multiplier)
#     multiplyField(["user_parameters","number_of_PD-1hi_CD137hi_CD8_Tcell"],cd8_multiplier)
#     multiplyField(["user_parameters","number_of_PD-1lo_CD137hi_CD8_Tcell"],cd8_multiplier)
#     multiplyField(["user_parameters","number_of_PD-1hi_CD137lo_CD8_Tcell"],cd8_multiplier)
#     multiplyField(["user_parameters","number_of_PD-1lo_CD137lo_CD8_Tcell"],cd8_multiplier)
#     save_file(getXML(), path_to_xml)
#     closeXML()
#     return gvax_cohort_id
# end

function addVariationColumns(base_config_id::Int, xml_paths::Vector{Vector{String}}, variable_types::Vector{DataType})
    folder_name = DBInterface.execute(db, "SELECT folder_name FROM base_configs WHERE (base_config_id)=($(base_config_id));") |> DataFrame |> x->x.folder_name[1]
    db_config = getConfigDB(base_config_id)
    column_names = DBInterface.execute(db_config, "PRAGMA table_info(variations);") |> DataFrame |> x->x[!,:name]
    filter!(x->x!="variation_id",column_names)
    varied_column_names = [join(xml_path,"/") for xml_path in xml_paths]

    is_new_column = [!(varied_column_name in column_names) for varied_column_name in varied_column_names]
    if any(is_new_column)
        new_column_names = varied_column_names[is_new_column]

        path_to_xml = "$(data_dir)/base_configs/$(folder_name)/PhysiCell_settings.xml"
        xml_doc = openXML(path_to_xml)
        default_values_for_new = [getField(xml_doc, xml_path) for xml_path in xml_paths[is_new_column]]
        closeXML(xml_doc)
        for (i, new_column_name) in enumerate(new_column_names)
            if variable_types[i] == Bool
                sqlite_data_type = "TEXT"
            elseif variable_types[i] <: Int
                sqlite_data_type = "INT"
            elseif variable_types[i] <: Real
                sqlite_data_type = "REAL"
            else
                sqlite_data_type = "TEXT"
            end
            DBInterface.execute(db_config, "ALTER TABLE variations ADD COLUMN '$(new_column_name)' $(sqlite_data_type);")
        end
        DBInterface.execute(db_config, "UPDATE variations SET ($(join("\"".*new_column_names.*"\"",",")))=($(join("\"".*default_values_for_new.*"\"",",")));")

        index_name = "variations_index"
        SQLite.dropindex!(db_config, index_name; ifexists=true) # remove previous index
        index_columns = deepcopy(column_names)
        append!(index_columns, new_column_names)
        SQLite.createindex!(db_config, "variations", index_name, index_columns; unique=true, ifnotexists=false) # add new index to make sure no variations are repeated
    end

    static_column_names = deepcopy(column_names)
    old_varied_names = varied_column_names[.!is_new_column]
    filter!( x->!(x in old_varied_names) , static_column_names)

    return static_column_names, varied_column_names
end

# function addVariationColumns(patient_id::Int, xml_paths::Vector{Vector{String}}, variable_types::Vector{DataType})
#     db = getDB()
#     table_name = "patient_variations_$(patient_id)"
#     column_names = DBInterface.execute(db, "PRAGMA table_info($(table_name));") |> DataFrame |> x->x[!,:name]
#     filter!(x->x!="variation_id",column_names)
#     varied_column_names = [join(xml_path,"/") for xml_path in xml_paths]

#     is_new_column = [!(varied_column_name in column_names) for varied_column_name in varied_column_names]
#     if any(is_new_column)
#         new_column_names = varied_column_names[is_new_column]

#         path_to_xml = selectRow("path", "folders", "WHERE patient_id=$(patient_id) AND cohort_id=$(control_cohort_id)")
#         path_to_xml *= "config/PhysiCell_settings.xml"
#         openXML(path_to_xml)
#         default_values_for_new = [getField(xml_path) for xml_path in xml_paths[is_new_column]]
#         closeXML()
#         for (i, new_column_name) in enumerate(new_column_names)
#             if variable_types[i] == Bool
#                 sqlite_data_type = "TEXT"
#             elseif variable_types[i] <: Int
#                 sqlite_data_type = "INT"
#             elseif variable_types[i] <: Real
#                 sqlite_data_type = "REAL"
#             else
#                 sqlite_data_type = "TEXT"
#             end
#             DBInterface.execute(db, "ALTER TABLE $(table_name) ADD COLUMN '$(new_column_name)' $(sqlite_data_type);")
#         end
#         DBInterface.execute(db, "UPDATE $(table_name) SET ($(join("\"".*new_column_names.*"\"",",")))=($(join("\"".*default_values_for_new.*"\"",",")));")

#         index_name = table_name * "_index"
#         SQLite.dropindex!(db, index_name; ifexists=true) # remove previous index
#         index_columns = deepcopy(column_names)
#         append!(index_columns, new_column_names)
#         SQLite.createindex!(db, table_name, index_name, index_columns; unique=true, ifnotexists=false) # add new index to make sure no variations are repeated
#     end

#     static_column_names = deepcopy(column_names)
#     old_varied_names = varied_column_names[.!is_new_column]
#     filter!( x->!(x in old_varied_names) , static_column_names)

#     return table_name, static_column_names, varied_column_names
# end

function addVariationRow(base_config_id::Int, table_features::String, values::String)
    db_config = getConfigDB(base_config_id)
    new_variation_id = DBInterface.execute(db_config, "INSERT OR IGNORE INTO variations ($(table_features)) VALUES($(values)) RETURNING variation_id;") |> DataFrame |> x->x.variation_id
    new_variation_added = length(new_variation_id)==1
    if  !new_variation_added
        new_variation_id = selectRow("variation_id", "variations", "WHERE ($(table_features))=($(values))"; db=db_config)
    end
    return new_variation_id[1], new_variation_added
end

function addVariationRow(base_config_id::Int, table_features::String, static_values::String, varied_values::String)
    return addVariationRow(base_config_id, table_features, "$(static_values)$(varied_values)")
end

"""
function addGridVariationToTable(patient_id::Int, D::Vector{Vector{Vector}}; reference_variation::Int=0)
Creates a grid of parameter values defined by D to the variations tables for a specified patient.
A reference variation id can be suppplied so that any currently unvaried values are pulled from that variation.
D is a vector of parameter info.
Each entry in D has two elements: D[i][1] is the xml_path based on the config file; D[i][2] is the vector of values to use for the ith parameter.
"""

function addGridVariationToTable(base_config_id::Int, D::Vector{Vector{Vector}}; reference_variation::Int=0)
    xml_paths = [d[1] for d in D]
    new_values = [d[2] for d in D]
    static_column_names, varied_column_names = addVariationColumns(base_config_id, xml_paths, [typeof(d[2][1]) for d in D])
    static_values, table_features = prepareAddNewVariations(base_config_id, static_column_names, varied_column_names; reference_variation = reference_variation)

    NDG = ndgrid(new_values...)
    sz_variations = size(NDG[1])
    variation_ids = zeros(Int, sz_variations)
    is_new_variation_id = falses(sz_variations)
    for i in eachindex(NDG[1])
        varied_values = [A[i] for A in NDG] .|> string |> x -> join("\"" .* x .* "\"", ",")
        variation_ids[i], is_new_variation_id[i] = addVariationRow(base_config_id, table_features, static_values, varied_values)
    end
    return variation_ids, is_new_variation_id
end

# function addGridVariationToTable(patient_id::Int, D::Vector{Vector{Vector}}; reference_variation::Int=0)
#     xml_paths = [d[1] for d in D]
#     new_values = [d[2] for d in D]
#     table_name, static_column_names, varied_column_names = addVariationColumns(patient_id, xml_paths, [typeof(d[2][1]) for d in D])
#     static_values, table_features = prepareAddNewVariations(table_name, static_column_names, varied_column_names; reference_variation = reference_variation)

#     NDG = ndgrid(new_values...)
#     sz_variations = size(NDG[1])
#     variation_ids = zeros(Int, sz_variations)
#     is_new_variation_id = falses(sz_variations)
#     for i in eachindex(NDG[1])
#         varied_values = [A[i] for A in NDG] .|> string |> x -> join("\"" .* x .* "\"", ",")
#         variation_ids[i], is_new_variation_id[i] = addVariationRow(table_name, table_features, static_values, varied_values)
#     end
#     return variation_ids, is_new_variation_id
# end

"""
function addGridVariationToTable(patient_id::Int, xml_paths::Vector{Vector{String}}, new_values::Vector{Vector{T}} where {T<:Real}; reference_variation::Int=0)
Does the same as addGridVariationToTable(patient_id::Int, D::Vector{Vector{Vector}}; reference_variation::Int=0) but first assembles D from xml_paths and new_values.
"""

# function addGridVariationToTable(patient_id::Int, xml_paths::Vector{Vector{String}}, new_values::Vector{Vector{T}} where {T<:Real}; reference_variation::Int=0)
#     D = [[xml_paths[i], new_values[i]] for i in eachindex(xml_paths)]
#     return addGridVariationToTable(patient_id, D; reference_variation=reference_variation)
# end

# function addSampleVariationToTable(patient_id::Int, xml_paths::Vector{Vector{String}}, parameter_matrix::Matrix{T} where T; reference_variation=0)
#     table_name, static_column_names, varied_column_names = addVariationColumns(patient_id, xml_paths, [typeof(parameter_matrix[1,i]) for i in axes(parameter_matrix,2)])
#     static_values, table_features = prepareAddNewVariations(table_name, static_column_names, varied_column_names; reference_variation = reference_variation)
    
#     sz_variations = size(parameter_matrix,1)
#     variation_ids = zeros(Int, sz_variations)
#     is_new_variation_id = falses(sz_variations)
#     for i in axes(parameter_matrix,1)
#         varied_values = [parameter_matrix[i,j] for j in axes(parameter_matrix,2)] .|> string |> x -> join("\"" .* x .* "\"", ",")
#         variation_ids[i], is_new_variation_id[i] = addVariationRow(base_config_id, table_features, static_values, varied_values)
#     end
#     return variation_ids, is_new_variation_id
# end

function prepareAddNewVariations(base_config_id::Int, static_column_names::Vector{String}, varied_column_names::Vector{String}; reference_variation::Int=0)
    static_values = selectRow(static_column_names, "variations", "WHERE variation_id=$(reference_variation)"; db=getConfigDB(base_config_id)) |> x -> join("\"" .* string.(x) .* "\"", ",")
    table_features = join("\"" .* static_column_names .* "\"", ",")
    if !isempty(static_column_names)
        static_values *= ","
        table_features *= ","
    end
    table_features *= join("\"" .* varied_column_names .* "\"", ",")
    return static_values, table_features
end

# function recordTrialInfo(simulation_ids::Vector{Int}, time_started::DateTime, description::String)
#     if isempty(description)
#         println("No description submitted for this trial. Do you think you can remember everything? No. Enter a description now:")
#         description = readline()
#     end
#     s =  "INSERT INTO trials (datetime,description) VALUES('$(Dates.format(time_started,"yymmddHHMM"))','$(description)') RETURNING trial_id;"
#     trial_id = DBInterface.execute(getDB(), s) |> DataFrame |> x -> x.trial_id[1]
#     recordTrialSimulationIDs(trial_id,simulation_ids)
# end

# function recordTrialSimulationIDs(trial_id::Int, simulation_ids::Vector{Int})
#     path_to_trial_folder = data_dir * "/trials/" * string(trial_id) * "/"
#     run(`mkdir -p $(path_to_trial_folder)`)
#     path_to_csv = path_to_trial_folder * "simulations.csv"
#     lines_table = compressSimulationIDs(simulation_ids)
#     CSV.write(path_to_csv, lines_table; writeheader=false)
# end

function compressSimulationIDs(simulation_ids::Vector{Int})
    sort!(simulation_ids)
    return compressIDs(simulation_ids)
end

function compressIDs(ids::Vector{Int})
    lines = String[]
    while !isempty(ids) # while there are still ids to compress
        if length(ids) == 1 # if there's only one id left
            next_line = string(ids[1]) # just add it to the list
            popfirst!(ids) # and remove it from the list of ids
        else # if there's more than one id left
            I = findfirst(diff(ids) .> 1) # find the first index where the difference between consecutive ids is greater than 1
            I = isnothing(I) ? length(ids) : I # if none found, then all the diffs are 1 so we want to take the entire list
            if I > 1 # if compressing multiple ids
                next_line = "$(ids[1]):$(ids[I])" # add the first and last id separated by a colon
                ids = ids[I+1:end] # remove the ids that were just compressed
            else # if only compressing one id
                next_line = string(ids[1]) # just add the id to the list
                popfirst!(ids) # and remove it from the list of ids
            end
        end
        push!(lines, next_line) # add the compressed id(s) to the list of lines
    end
    return Tables.table(lines)
end

function compressMonadIDs(monad_ids::Array{Int})
    monad_ids = vec(monad_ids)
    return compressIDs(monad_ids)
end

# function selectTrialSimulations(trial_id::Int)
#     path_to_trial = data_dir * "/trials/" * string(trial_id) * "/"
#     df = CSV.read(path_to_trial*"simulations.csv",DataFrame; header=false,silencewarnings=true,types=String,delim=",")
#     simulation_ids = Int[]
#     for i in axes(df,1)
#         s = df.Column1[i]
#         I = split(s,":") .|> string .|> x->parse(Int,x)
#         if length(I)==1
#             push!(simulation_ids,I[1])
#         else
#             append!(simulation_ids,I[1]:I[2])
#         end
#     end
#     return simulation_ids
# end

function selectConstituents(path_to_csv::String)
    if !isfile(path_to_csv)
        return Int[]
    end
    df = CSV.read(path_to_csv, DataFrame; header=false, silencewarnings=true, types=String, delim=",")
    ids = Int[]
    for i in axes(df,1)
        s = df.Column1[i]
        I = split(s,":") .|> string .|> x->parse(Int,x)
        if length(I)==1
            push!(ids,I[1])
        else
            append!(ids,I[1]:I[2])
        end
    end
    return ids
end

getMondadSimulations(monad_id::Int) = selectConstituents("$(data_dir)/monads/$(monad_id)/simulations.csv")
getSamplingMonads(sampling_id::Int) = selectConstituents("$(data_dir)/samplings/$(sampling_id)/monads.csv")

end