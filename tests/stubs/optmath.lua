local optmath = {}
function optmath.roundPercent(x)
    return math.floor(x * 100 + 0.5) / 100
end
function optmath.round(x)
    return math.floor(x + 0.5)
end
return optmath
