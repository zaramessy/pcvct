db = SQLite.DB()

current_base_config_id = Int[]
current_ic_id = Int[]
current_custom_code_id = Int[]

function initializeDatabase(path_to_database::String)
    global db = SQLite.DB(path_to_database)
    return createSchema()
end

function initializeDatabase()
    global db = SQLite.DB()
    return createSchema()
end

function createSchema()

    cd(data_dir)
    
    data_dir_contents = readdir(sort=false)
    if !("custom_codes" in data_dir_contents)
        error("No $(data_dir)/custom_codes found. This is where to put the folders for custom_modules, main.cpp, and Makefile.")
    end
    if !("base_configs" in data_dir_contents)
        error("No $(data_dir)/base_configs found. This is where to put the folders for config files and rules files.")
    end
    
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS custom_codes (
        custom_code_id INTEGER PRIMARY KEY,
        folder_name UNIQUE,
        description TEXT
        )
    ")
        
    custom_codes_folders = readdir("custom_codes", sort=false) |> filter(x->isdir("custom_codes/$(x)"))
    if isempty(custom_codes_folders)
        error("No folders in $(data_dir)/custom_codes found. Add custom_modules, main.cpp, and Makefile to a folder here to move forward.")
    end
    # probably a more efficient way to do this, but just loop through the custom code folders found and make sure they're in the table and make sure current_custom_code_id is set
    set_current_custom_code_id = isempty(current_custom_code_id)
    for custom_codes_folder in custom_codes_folders
        s = "INSERT OR IGNORE INTO custom_codes (folder_name) VALUES ('$(custom_codes_folder)')"
        if set_current_custom_code_id
            global current_custom_code_id = DBInterface.execute(db, "$(s) RETURNING custom_code_id;") |> DataFrame |> x->x.custom_code_id
            set_current_custom_code_id = false
        else
            DBInterface.execute(db, s)
        end
    end
    
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS ics (
        ic_id INTEGER PRIMARY KEY,
        folder_name UNIQUE,
        description TEXT
        )
    ")
        
    if "ics" in data_dir_contents
        ics_folders = readdir("ics", sort=false) |> filter(x->isdir("ics/$(x)"))
        if !isempty(ics_folders)
            # probably a more efficient way to do this, but just loop through the custom code folders found and make sure they're in the table and make sure current_custom_code_id is set
            set_current_ic_id = isempty(current_ic_id)
            for ics_folder in ics_folders
                s = "INSERT OR IGNORE INTO ics (folder_name) VALUES ('$(ics_folder)')"
                if set_current_ic_id
                    global current_ic_id = DBInterface.execute(db, "$(s) RETURNING ic_id;") |> DataFrame |> x -> x.ic_id
                    set_current_ic_id = false
                else
                    DBInterface.execute(db, s)
                end
                current_ic_id = isempty(current_ic_id) ? temp : current_ic_id
            end
        end
    end
        
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS base_configs (
        base_config_id INTEGER PRIMARY KEY,
        folder_name UNIQUE,
        description TEXT
        )
    ")
        
    base_configs_folders = readdir("base_configs", sort=false) |> filter(x->isdir("base_configs/$(x)"))
    if isempty(base_configs_folders)
        error("No folders in $(data_dir)/base_configs found. Add PhysiCell_settings.xml and rules files here.")
    end
    # probably a more efficient way to do this, but just loop through the custom code folders found and make sure they're in the table and make sure current_custom_code_id is set
    set_current_base_config_id = isempty(current_base_config_id)
    for base_configs_folder in base_configs_folders
        s = "INSERT OR IGNORE INTO base_configs (folder_name) VALUES ('$(base_configs_folder)')"
        if set_current_base_config_id
            global current_base_config_id = DBInterface.execute(db, "$(s) RETURNING base_config_id;") |> DataFrame |> x->x.base_config_id
            set_current_base_config_id = false
        else
            DBInterface.execute(db, s)
        end
    end
            
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS simulations (
        simulation_id INTEGER PRIMARY KEY,
        custom_code_id INTEGER,
        ic_id INTEGER,
        base_config_id INTEGER,
        variations_id INTEGER,
        FOREIGN KEY (custom_code_id)
            REFERENCES custom_codes (custom_code_id),
        FOREIGN KEY (ic_id)
            REFERENCES ics (ic_id)
        FOREIGN KEY (base_config_id)
            REFERENCES base_configs (base_config_id)
        )    
    ")

    # SQLite.execute(db, "CREATE TABLE IF NOT EXISTS trials (
    #     trial_id INTEGER PRIMARY KEY,
    #     datetime TEXT,
    #     description TEXT
    #     )
    # ")
    return
end

function selectRow(table_name::String, condition_stmt::String)
    s = "SELECT * FROM $(table_name) " * condition_stmt * ";"
    df = DBInterface.execute(db, s) |> DataFrame
    @assert size(df,1)==1 "Did not find exactly one row matching the query:\n\tDatabase file: $(db)\n\tQuery: $(s)\nResult: $(df)"
    return df
end

function selectRow(column_names::Vector{String}, table_name::String, condition_stmt::String)
    df = selectRow(table_name, condition_stmt)
    return [df[1,column_name] for column_name in column_names]
end

function selectRow(column_name::String, table_name::String, condition_stmt::String)
    df = selectRow(table_name, condition_stmt)
    return df[1,column_name]
end

function getFolderID(patient_id::Int,cohort_id::Int)
    return selectRow("folder_id","folders","WHERE patient_id=$(patient_id) AND cohort_id=$(cohort_id)")
end

function retrieveFolderInfo(folder_id::Int)
    return selectRow("folders","WHERE folder_id=$(folder_id)")
end

function retrievePathInfo(base_config_id::Int, ic_id::Int, custom_code_id::Int)
    base_config_path = DBInterface.execute(db, "SELECT path FROM configurations WHERE configuration_id=$(base_config_id)") |> DataFrame |> x -> x.path
    ics_path = DBInterface.execute(db, "SELECT path FROM ics WHERE ic_id=$(ic_id)") |> DataFrame |> x -> x.path
    custom_code_path = DBInterface.execute(db, "SELECT path FROM custom_codes WHERE custom_code_id=$(custom_code_id)") |> DataFrame |> x -> x.path
    return base_config_path, ics_path, custom_code_path
end
