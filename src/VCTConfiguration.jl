export ElementaryVariation, addCustomDataVariationDimension!

function getConfigDB(base_config_folder::String)
    return "$(data_dir)/inputs/base_configs/$(base_config_folder)/variations.db" |> SQLite.DB
end

getConfigDB(base_config_id::Int) = getBaseConfigFolder(base_config_id) |> getConfigDB
getConfigDB(S::AbstractSampling) = getConfigDB(S.folder_names.base_config_folder)

function getRulesetsCollectionsDB(base_config_folder::String)
    return (isabspath(base_config_folder) ? "$(base_config_folder)/rulesets_collections.db" : "$(data_dir)/inputs/base_configs/$(base_config_folder)/rulesets_collections.db") |> SQLite.DB
end

getRulesetsCollectionsDB(S::AbstractSampling) = getRulesetsCollectionsDB(S.folder_names.base_config_folder)
getRulesetsCollectionsDB(base_config_id::Int) = getRulesetsCollectionsDB(getBaseConfigFolder(base_config_id))

function getRulesetsVariationsDB(base_config_folder::String, rulesets_collection_folder::String)
    return "$(data_dir)/inputs/base_configs/$(base_config_folder)/rulesets_collections/$(rulesets_collection_folder)/rulesets_variations.db" |> SQLite.DB
end

getRulesetsVariationsDB(M::AbstractMonad) = getRulesetsVariationsDB(M.folder_names.base_config_folder, M.folder_names.rulesets_collection_folder)
getRulesetsVariationsDB(base_config_id::Int, rulesets_collection_id::Int) = getRulesetsVariationsDB(getBaseConfigFolder(base_config_id), getRulesetsCollectionFolder(base_config_id, rulesets_collection_id))

function openXML(path_to_xml::String)
    return parse_file(path_to_xml)
end

closeXML(xml_doc::XMLDocument) = free(xml_doc)

function retrieveElement(xml_doc::XMLDocument, xml_path::Vector{String}; required::Bool=true)
    current_element = root(xml_doc)
    for path_element in xml_path
        if !occursin(":",path_element)
            current_element = find_element(current_element, path_element)
            if isnothing(current_element)
                error_msg = "Element not found: $(join(xml_path, " -> "))"
                required ? error(error_msg) : return nothing
            end
            continue
        end
        # Deal with checking attributes
        path_element_name, attribute_check = split(path_element,":",limit=2)
        attribute_name, attribute_value = split(attribute_check,":") # if I need to add a check for multiple attributes, we can do that later
        candidate_elements = get_elements_by_tagname(current_element, path_element_name)
        found = false
        for ce in candidate_elements
            if attribute(ce,attribute_name)==attribute_value
                found = true
                current_element = ce
                break
            end
        end
        if !found
            error_msg = "Element not found: $(join(xml_path, "//"))"
            error_msg *= "\n\tFailed at: $(path_element)"
            required ? error(error_msg) : return nothing
        end
    end
    return current_element
end

function retrieveElement(path_to_xml::String,xml_path::Vector{String}; required::Bool=true)
    return openXML(path_to_xml) |> x->retrieveElement(x, xml_path; required=required)
end

function getField(xml_doc::XMLDocument, xml_path::Vector{String}; required::Bool=true)
    return retrieveElement(xml_doc, xml_path; required=required) |> content
end

function getOutputFolder(path_to_xml)
    xml_doc = openXML(path_to_xml)
    rel_path_to_output = getField(xml_doc, ["save", "folder"])
    closeXML(xml_doc)
    return rel_path_to_output
end

function updateField(xml_doc::XMLDocument, xml_path::Vector{String},new_value::Union{Int,Real,String})
    current_element = retrieveElement(xml_doc, xml_path; required=true)
    set_content(current_element, string(new_value))
    return nothing
end

function updateField(xml_doc::XMLDocument, xml_path_and_value::Vector{Any})
    return updateField(xml_doc, xml_path_and_value[1:end-1],xml_path_and_value[end])
end

function updateField(path_to_xml::String,xml_path::Vector{String},new_value::Union{Int,Real,String})
    return openXML(path_to_xml) |> x -> updateField(x, xml_path, new_value)
end

function multiplyField(xml_doc::XMLDocument, xml_path::Vector{String}, multiplier::AbstractFloat)
    current_element = retrieveElement(xml_doc, xml_path; required=true)
    val = content(current_element)
    if attribute(current_element, "type"; required=false) == "int"
        val = parse(Int, val) |> y -> round(Int, multiplier * y)
    else
        val = parse(AbstractFloat, val) |> y -> multiplier * y
    end

    val |> string |> x -> set_content(current_element, x)
    return nothing
end

function updateFieldsFromCSV(xml_doc::XMLDocument, path_to_csv::String)
    df = CSV.read(path_to_csv,DataFrame;header=false,silencewarnings=true,types=String)
    for i = axes(df,1)
        df[i, :] |> Vector |> x -> filter!(!ismissing, x) .|> string |> x -> updateField(xml_doc, x)
    end
end

function updateFieldsFromCSV(path_to_csv::String,path_to_xml::String)
    return openXML(path_to_xml) |> x->updateFieldsFromCSV(x, path_to_csv)
end

function loadConfiguration(M::AbstractMonad)
    path_to_xml = "$(data_dir)/inputs/base_configs/$(M.folder_names.base_config_folder)/variations/variation_$(M.variation_id).xml"
    if isfile(path_to_xml)
        return
    end
    mkpath(dirname(path_to_xml))
    path_to_xml_src = "$(data_dir)/inputs/base_configs/$(M.folder_names.base_config_folder)/PhysiCell_settings.xml"
    cp(path_to_xml_src, path_to_xml, force=true)

    xml_doc = openXML(path_to_xml)
    variation_row = selectRow("variations", "WHERE variation_id=$(M.variation_id);", db=getConfigDB(M.folder_ids.base_config_id))
    for column_name in names(variation_row)
        if column_name == "variation_id"
            continue
        end
        xml_path = split(column_name,"/") .|> string
        updateField(xml_doc, xml_path,variation_row[1,column_name])
    end
    save_file(xml_doc, path_to_xml)
    closeXML(xml_doc)
    return
end

function loadConfiguration(sampling::Sampling)
    for index in eachindex(sampling.variation_ids)
        monad = Monad(sampling, index) # instantiate a monad with the variation_id and the simulation ids already found
        loadConfiguration(monad)
    end
end

function loadRulesets(M::AbstractMonad)
    if M.rulesets_variation_id == -1
        return
    end
    path_to_rulesets_xml = "$(data_dir)/inputs/base_configs/$(M.folder_names.base_config_folder)/rulesets_collections/$(M.folder_names.rulesets_collection_folder)/rulesets_variation_$(M.rulesets_variation_id).xml"
    if isfile(path_to_rulesets_xml)
        return
    end
    mkpath(dirname(path_to_rulesets_xml))

    # create xml file using LightXML
    xml_doc = parse_file("$(data_dir)/inputs/base_configs/$(M.folder_names.base_config_folder)/rulesets_collections/$(M.folder_names.rulesets_collection_folder)/base_rulesets.xml")
    if M.rulesets_variation_id != 0 # only update if not using hte base variation for the ruleset
        variation_row = selectRow("rulesets_variations", "WHERE rulesets_variation_id=$(M.rulesets_variation_id);", db=getRulesetsVariationsDB(M))
        for column_name in names(variation_row)
            if column_name == "rulesets_variation_id"
                continue
            end
            xml_path = split(column_name, "/") .|> string
            updateField(xml_doc, xml_path, variation_row[1, column_name])
        end
    end
    save_file(xml_doc, path_to_rulesets_xml)
    closeXML(xml_doc)
    return
end

function cellDefinitionPath(cell_definition::String)
    return ["cell_definitions", "cell_definition:name:$(cell_definition)"]
end

function phenotypePath(cell_definition::String)
    return [cellDefinitionPath(cell_definition); "phenotype"]
end

cyclePath(cell_definition::String) = [phenotypePath(cell_definition); "cycle"]
deathPath(cell_definition::String) = [phenotypePath(cell_definition); "death"]
apoptosisPath(cell_definition::String) = [deathPath(cell_definition); "model:code:100"]
necrosisPath(cell_definition::String) = [deathPath(cell_definition); "model:code:101"]

motilityPath(cell_definition::String) = [phenotypePath(cell_definition); "motility"]
motilityPath(cell_definition::String, field_name::String) = [motilityPath(cell_definition); field_name]

################## Variation Dimension Functions ##################
struct ElementaryVariation{T}
    xml_path::Vector{String}
    values::Vector{T}
end

function addMotilityVariationDimension!(D::Vector{Vector{Vector}}, cell_definition::String, field_name::String, values::Vector{T} where T)
    xml_path = motilityPath(cell_definition, field_name)
    new_var = [xml_path, values]
    push!(D, new_var)
end

function addMotilityVariationDimension!(EV::Vector{ElementaryVariation}, cell_definition::String, field_name::String, values::Vector{T} where T)
    xml_path = motilityPath(cell_definition, field_name)
    push!(EV, ElementaryVariation(xml_path, values))
end

function customDataPath(cell_definition::String, field_name::String)
    return ["cell_definitions", "cell_definition:name:$(cell_definition)", "custom_data", field_name]
end

function customDataPath(cell_definition::String, field_names::Vector{String})
    return [customDataPath(cell_definition, field_name) for field_name in field_names]
end

function addCustomDataVariationDimension!(D::Vector{Vector{Vector}}, cell_definition::String, field_name::String, values::Vector{T} where T)
    xml_path = customDataPath(cell_definition, field_name)
    new_var = [xml_path, values]
    push!(D, new_var)
end

function addCustomDataVariationDimension!(EV::Vector{ElementaryVariation}, cell_definition::String, field_name::String, values::Vector{T} where T)
    xml_path = customDataPath(cell_definition, field_name)
    push!(EV, ElementaryVariation(xml_path, values))
end

function addCustomDataVariationDimension!(D::Vector{Vector{Vector}}, cell_definition::String, field_names::Vector{String}, values::Vector{Vector})
    for (field_name, value) in zip(field_names,values)
        addCustomDataVariationDimension!(D, cell_definition, field_name, value)
    end
end

function addCustomDataVariationDimension!(EV::Vector{ElementaryVariation}, cell_definition::String, field_names::Vector{String}, values::Vector{Vector})
    for (field_name, value) in zip(field_names,values)
        addCustomDataVariationDimension!(EV, cell_definition, field_name, value)
    end
end

function userParameterPath(field_name::String)
    return ["user_parameters", field_name]
end

function userParameterPath(field_names::Vector{String})
    return [userParameterPath(field_name) for field_name in field_names]
end

function initialConditionPath()
    return ["initial_conditions","cell_positions","filename"]
end

function simpleVariationNames(name::String)
    if name == "variation_id"
        return "ID"
    elseif name == "overall/max_time"
        return "Max Time"
    elseif name == "save/full_data/interval"
        return "Full Save Interval"
    elseif name == "save/SVG/interval"
        return "SVG Save Interval"
    elseif startswith(name, "cell_definitions")
        return getCellParameter(name)
    else
        return name
    end
end

function getCellParameter(column_name::String)
    xml_path = split(column_name, "/") .|> string
    cell_def = split(xml_path[2], ":")[3]
    par_name = xml_path[end]
    return replace("$(cell_def): $(par_name)", '_' => ' ')
end
