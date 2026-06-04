abstract type AbstractMacroModel end

"""
    model_name(m) -> String

モデルの名称を返す。
"""
function model_name end

"""
    state_variables(m) -> Vector{Symbol}

状態変数の名称リストを返す。
"""
function state_variables end

"""
    control_variables(m) -> Vector{Symbol}

操作変数（制御変数）の名称リストを返す。
"""
function control_variables end

"""
    parameters(m) -> NamedTuple

モデルのパラメータ一覧を NamedTuple で返す。
"""
function parameters end

"""
    steady_state(m) -> NamedTuple

定常状態を計算し、変数名をキーとする NamedTuple で返す。
"""
function steady_state end

"""
    transition_path(m, initial_state...; T) -> NamedTuple

完全予見均衡経路を計算し、変数名をキーとする NamedTuple で返す。
"""
function transition_path end

"""
    simulate(m, initial_state...; T) -> NamedTuple

動学シミュレーションを行い、変数名をキーとする NamedTuple で返す。
"""
function simulate end

"""
    impulse_response(m, shock_size; T) -> NamedTuple

インパルス応答を計算し、変数名をキーとする NamedTuple で返す。
"""
function impulse_response end
