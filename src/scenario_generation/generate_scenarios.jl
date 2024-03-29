using Distributions
using PowerModels
using ArgParse
using PrettyTables
using DataFrames
using CSV
using Random
using JSON
using ZipFile

PMs = PowerModels
PMs.silence()

""" code for all the scenario generation runs 

julia --project=. src/scenario_generation/generate_scenarios.jl 
julia --project=. src/scenario_generation/generate_scenarios.jl --case CATS.m --use_clusters --num_min_outages 15 --num_max_outages 30 --num_scenarios 1000
julia --project=. src/scenario_generation/generate_scenarios.jl --case pglib_opf_case240_pserc.m --use_clusters --num_min_outages 10 --num_max_outages 20 --num_scenarios 1000
julia --project=. src/scenario_generation/generate_scenarios.jl --case RTS_GMLC.m --use_clusters --num_min_outages 4 --num_max_outages 6 --num_scenarios 200
"""

function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        "--case", "-c"
        help = "case file name"
        arg_type = String
        default = "pglib_opf_case14_ieee.m"
        
        "--data_path", "-p"
        help = "data directory path"
        arg_type = String
        default = chop(Base.active_project(), tail = length("Project.toml")) * "data/"

        "--output_path"
        help = "output directory path"
        arg_type = String 
        default = chop(Base.active_project(), tail = length("Project.toml")) * "data/scenario_data/"

        "--num_scenarios", "-n"
        help = "number of scenarios to be generated"
        arg_type = Int
        default = 200

        "--num_max_outages"
        help = "maximum number of line/gen outages in each scenario"
        arg_type = Int 
        default = 4 

        "--num_min_outages"
        help = "minimum number of line/gen outages in each scenario" 
        arg_type = Int 
        default = 1

        "--use_clusters"
        help = "flag to use the clustering data for the case file"
        action = :store_true
    end

    return parse_args(s)
end

function main()
    cliargs = parse_commandline()
    
    # print the input parameters 
    pretty_table(cliargs, 
        title = "CLI parameters", 
        title_alignment = :c, 
        title_same_width_as_table = true, 
        show_header = false)

    validate_parameters(cliargs)
    files = get_filenames_with_paths(cliargs)
    run(cliargs, files)
    return 
end 

function validate_parameters(params)
    mkpath(params["data_path"])
    mkpath(params["output_path"])
    case_file = params["data_path"] * "matpower/" * params["case"]
    if isfile(case_file) == false
        @error "$case_file does not exist, quitting."
        exit() 
    end  
end 


function get_filenames_with_paths(params)
    case_name = chop(params["case"], tail = length(".m"))
    matpower_file = params["data_path"] * "matpower/" * params["case"]
    scenario_file = params["data_path"] * "scenario_data/" * case_name * ".json"
    zip_file = params["data_path"] * "scenario_data/" * case_name * ".zip"
    cluster_file = params["data_path"] * "gis/" * case_name * "_cluster.csv"
    return (mp_file = matpower_file, 
        scenario_file = scenario_file, 
        cluster_file = cluster_file,
        zip_file = zip_file)
end 

function run(cliargs, files)
    mp_file = files.mp_file 
    scenario_file = files.scenario_file 
    cluster_file = files.cluster_file
    zip_file = files.zip_file
    (isfile(scenario_file)) && (@warn "$scenario_file exists, overwriting")
    (cliargs["use_clusters"] && !isfile(cluster_file)) && (@error "$cluster_file does not exists, quitting"; exit())

    data = PMs.parse_file(mp_file)
    ref = PMs.build_ref(data)[:it][:pm][:nw][0]
    @info "number of buses: $(length(ref[:bus]))"
    Random.seed!(0)

    if cliargs["use_clusters"] == false
        line_ids = ref[:branch] |> keys 
        gen_ids = ref[:gen] |> keys
        components = ["line", "gen"]

        num_outages = cliargs["num_max_outages"]
        scenarios = Dict()
        for i in 1:cliargs["num_scenarios"]
            scenarios[i] = Dict("branch" => [] , "gen" => []) 
            for _ in 1:num_outages 
                component = rand(components)
                (component == "line") && (push!(scenarios[i]["branch"], rand(line_ids)))
                (component == "gen") && (push!(scenarios[i]["gen"], rand(gen_ids)))
            end 
            unique!(scenarios[i]["branch"])
            unique!(scenarios[i]["gen"])
        end 

        open(scenario_file, "w") do f 
            JSON.print(f, scenarios, 2) 
        end

        zip(zip_file, scenario_file)
        # Base.run(`tar -zcvf $tar_file --absolute-paths $(split(scenario_file, "/")[end])`)
        Base.run(`rm -f $scenario_file`)
    else 
        df = DataFrame(CSV.File(cluster_file))
        gdf = groupby(df, :cluster_id)
        num_clusters = length(gdf)
        cluster_info = Dict()
        for i in 1:num_clusters
            cluster = gdf[i]
            buses = cluster[!, "bus_id"] |> collect 
            cluster_info[i] = buses
        end 
        scenario_files = []

        for (cluster_id, buses) in cluster_info 
            gen_ids = filter(x -> last(x)["gen_bus"] in buses, ref[:gen]) |> keys 
            line_ids = filter(x -> last(x)["f_bus"] in buses && last(x)["t_bus"] in buses, ref[:branch]) |> keys
            components = ["line", "gen"]
            num_outages = range(cliargs["num_min_outages"], cliargs["num_max_outages"])
            
            scenarios = Dict() 
            for i in 1:cliargs["num_scenarios"]
                scenarios[i] = Dict("branch" => [] , "gen" => []) 
                k = rand(num_outages)
                for _ in 1:k
                    component = rand(components)
                    (component == "line") && (push!(scenarios[i]["branch"], rand(line_ids)))
                    (component == "gen") && (push!(scenarios[i]["gen"], rand(gen_ids)))
                end 
                unique!(scenarios[i]["branch"])
                unique!(scenarios[i]["gen"])
            end 
            
            new_scenario_file = chop(scenario_file, tail = length(".json")) * "_$(cluster_id).json"
            push!(scenario_files, new_scenario_file)
            open(new_scenario_file, "w") do f 
                JSON.print(f, scenarios, 2) 
            end
        end 
        zip(zip_file, scenario_files)
        map(x -> Base.run(`rm -f $x`), scenario_files)
    end 
end 

function zip(zip, files::Vector)
    compress = true 
    zdir = ZipFile.Writer(zip)
    for file in files 
        f = open(file, "r")
        content = read(f, String)
        close(f)

        zf = ZipFile.addfile(zdir, split(file, "/")[end]; method=(compress ? ZipFile.Deflate : ZipFile.Store));
        write(zf, content)
    end 
    close(zdir)
end 


function zip(zip, file)
    compress = true
    zdir = ZipFile.Writer(zip) 
    f = open(file, "r")
    content = read(f, String)
    close(f)

    zf = ZipFile.addfile(zdir, split(file, "/")[end]; method=(compress ? ZipFile.Deflate : ZipFile.Store));
    write(zf, content)
    close(zdir)
end 

main()