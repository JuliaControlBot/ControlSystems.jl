@doc """Evaluate the frequency response

`H(jw) = C*((jwI -A)^-1)*B + D`

of system `sys` over the frequency vector `w`.""" ->
function freqresp{S<:Real}(sys::LTISystem, w::AbstractVector{S})
    ny, nu = size(sys)
    nw = length(w)
    # Create imaginary freq vector s
    if !iscontinuous(sys)
        Ts = sys.Ts == -1 ? 1.0 : sys.Ts
        s = exp(w*im*Ts)
    else
        s = im*w
    end
    #Evil but nessesary type instability here
    sys = _preprocess_for_freqresp(sys)
    resp = Array(Complex128, ny, nu, nw)
    for i=1:nw
        # TODO : This doesn't actually take advantage of Hessenberg structure
        # for statespace version.
        resp[:, :, i] = evalfr(sys, s[i])
    end
    return resp, w
end

# Implements algorithm found in:
# Laub, A.J., "Efficient Multivariable Frequency Response Computations",
# IEEE Transactions on Automatic Control, AC-26 (1981), pp. 407-408.
function _preprocess_for_freqresp(sys::StateSpace)
    A, B, C, D = sys.A, sys.B, sys.C, sys.D
    F = hessfact(A)
    H = F[:H]::Matrix{Float64}
    T = full(F[:Q])
    P = C*T
    Q = T\B
    StateSpace(H, Q, P, D, sys.Ts, sys.statenames, sys.inputnames,
        sys.outputnames)
end

function _preprocess_for_freqresp(sys::TransferFunction)
    map(sisotf -> _preprocess_for_freqresp(sisotf), sys.matrix)
end

_preprocess_for_freqresp(sys::SisoTf) = sys

@doc """Evaluate the frequency response

`H(s) = C*((sI - A)^-1)*B + D`

of system `sys` at value `s`. For many values of `s`, use `freqresp` instead.""" ->
function evalfr(sys::StateSpace, s::Number)
    S = promote_type(typeof(s), Float64)
    try
        R = Diagonal(S[s for i=1:sys.nx]) - sys.A
        sys.D + sys.C*((R\sys.B)::Matrix{S})  # Weird type stability issue
    catch
        fill(convert(S, Inf), size(sys))
    end
end

function evalfr(sys::TransferFunction, s::Number)
    S = promote_type(typeof(s), Float64)
    mat = sys.matrix
    ny, nu = size(mat)
    res = Array(S, ny, nu)
    for j = 1:nu
        for i = 1:ny
            res[i, j] = evalfr(mat[i, j], s)
        end
    end
    return res
end

#This is called after _preprocess_for_freqresp
function evalfr(mat::Matrix, s::Number)
    S = promote_type(typeof(s), Float64)
    res = Array(S, size(mat)...)
    for i in eachindex(mat)
        res[i] = evalfr(mat[i], s)
    end
    return res
end

function Base.call(sys::TransferFunction, s)
    evalfr(sys,s)
end

function Base.call(sys::TransferFunction, s::Number, map_to_unit_circle::Bool)
    @assert !iscontinuous(sys) "It makes no sense to call this function with continuous systems"
    evalfr(sys,exp(im*s.*sys.Ts))
end

function Base.call(sys::TransferFunction, s::AbstractVector, map_to_unit_circle::Bool)
    @assert !iscontinuous(sys) "It makes no sense to call this function with continuous systems"
    freqresp(sys,s)
end

@doc """`mag, phase, w = bode(sys[, w])`

Compute the magnitude and phase parts of the frequency response of system `sys`
at frequencies `w`""" ->
function bode(sys::LTISystem, w::AbstractVector)
    resp = freqresp(sys, w)[1]
    return abs(resp), rad2deg(unwrap!(angle(resp),3)), w
end
bode(sys::LTISystem) = bode(sys, _default_freq_vector(sys, :bode))

@doc """`re, im, w = nyquist(sys[, w])`

Compute the real and imaginary parts of the frequency response of system `sys`
at frequencies `w`""" ->
function nyquist(sys::LTISystem, w::AbstractVector)
    resp = freqresp(sys, w)[1]
    return real(resp), imag(resp), w
end
nyquist(sys::LTISystem) = nyquist(sys, _default_freq_vector(sys, :nyquist))

@doc """`sv, w = sigma(sys[, w])`

Compute the singular values of the frequency response of system `sys` at
frequencies `w`""" ->
function sigma(sys::LTISystem, w::AbstractVector)
    resp = freqresp(sys, w)[1]
    ny, nu, nw = size(resp)
    sv = Array(Float64, min(ny, nu), nw)
    for i=1:nw
        sv[:, i] = svdvals(resp[:, :, i])
    end
    return sv, w
end
sigma(sys::LTISystem) = sigma(sys, _default_freq_vector(sys, :sigma))

function _default_freq_vector{T<:LTISystem}(systems::Vector{T}, plot::Symbol)
    min_pt_per_dec = 60
    min_pt_total = 200
    nsys = length(systems)
    bounds = Array(Float64, 2, nsys)
    for i=1:nsys
        # TODO : For now we ignore the feature information. In the future,
        # these can be used to improve the frequency vector near features.
        bounds[:, i] = _bounds_and_features(systems[i], plot)[1]
    end
    w1 = minimum(bounds)
    w2 = maximum(bounds)
    nw = round(Int, max(min_pt_total, min_pt_per_dec*(w2 - w1)))
    return logspace(w1, w2, nw)
end
_default_freq_vector(sys::LTISystem, plot::Symbol) = _default_freq_vector(
        LTISystem[sys], plot)

_default_freq_vector{T<:TransferFunction{SisoGeneralized}}(sys::Vector{T}, plot::Symbol) =
    logspace(-2,2,400)
_default_freq_vector(sys::TransferFunction{SisoGeneralized} , plot::Symbol) =
    logspace(-2,2,400)


function _bounds_and_features(sys::LTISystem, plot::Symbol)
    # Get zeros and poles for each channel
    if plot != :sigma
        zs, ps = zpkdata(sys)
        # Compose vector of all zs, ps, positive conjugates only.
        zp = vcat([vcat(i, j) for (i, j) in zip(zs, ps)]...)
        zp = zp[imag(zp) .>= 0.0]
    else
        # For sigma plots, use the MIMO poles and zeros
        zp = [tzero(sys); pole(sys)]
    end
    # Get the frequencies of the features, ignoring low frequency dynamics
    fzp = log10(abs(zp))
    fzp = fzp[fzp .> -4]
    fzp = sort!(fzp)
    # Determine the bounds on the frequency vector
    if !isempty(fzp)
        w1 = floor(fzp[1] - 0.2)
        w2 = ceil(fzp[end] + 0.2)
        # Expand the range for nyquist plots
        if plot == :nyquist
            w1 -= 1
            w2 += 1
        end
    else
        w1 = 0
        w2 = 2
    end
    return [w1, w2], zp
end
