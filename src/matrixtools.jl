# MadNLP.jl
# Created by Sungho Shin (sungho.shin@wisc.edu)

abstract type AbstractSparseMatrixCOO{Tv,Ti<:Integer} <: AbstractSparseMatrix{Tv,Ti} end
mutable struct SparseMatrixCOO{Tv,Ti<:Integer} <: AbstractSparseMatrixCOO{Tv,Ti}
    m::Int
    n::Int
    I::AbstractArray{Ti,1}
    J::AbstractArray{Ti,1}
    V::AbstractArray{Tv,1}
end
function string(coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer}
    """
        SpasreMatrixCOO
    """
end
print(io::IO,coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer} = print(io,string(coo))
show(io::IO,::MIME"text/plain",coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer} = print(io,coo)
size(A::SparseMatrixCOO) = (A.m,A.n)
getindex(A::SparseMatrixCOO{Float64,Ti},i::Int,j::Int) where Ti <: Integer = sum(A.V[(A.I.==i) .* (A.J.==j)])
nnz(A::SparseMatrixCOO) = length(A.I)

SparseMatrixCOO(csc::SparseMatrixCSC{Tv,Ti}) where {Tv,Ti<:Integer} = SparseMatrixCOO{Tv,Ti}(
    csc.m,csc.n,findIJ(csc)...,csc.nzval)
SparseMatrixCSC(coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer} = sparse(coo.I,coo.J,coo.V,coo.m,coo.n)

symv!(y::StrideOneVector{Float64},A::SparseMatrixCSC{Float64,Int32},x::StrideOneVector{Float64}) =
    (length(y) > 0 && length(x) >0) &&
    ccall((:mkl_dcsrsymv,libmkl32),
          Cvoid,
          (Ref{Cchar},Ref{Int32},Ptr{Float64},Ptr{Int32},Ptr{Int32},Ptr{Float64},Ptr{Float64}),
          'u',Int32(A.n),A.nzval,A.colptr,A.rowval,x,y)
mv!(y::StrideOneVector{Float64},A::SparseMatrixCSC{Float64,Int32},x::StrideOneVector{Float64};
    alpha::Float64=1.,beta::Float64=0.) = (length(y) > 0) &&
        ccall((:mkl_dcscmv,libmkl32),
              Cvoid,
              (Ref{Cchar},Ref{Int32},Ref{Int32},Ref{Float64},Ptr{Cchar},Ptr{Float64},Ptr{Int32},
               Ptr{Int32},Ptr{Int32},Ptr{Float64},Ref{Float64},Ptr{Float64}),
              'n',Int32(A.m),Int32(A.n),alpha,"G00000",A.nzval,A.rowval,
              pointer(A.colptr),pointer(A.colptr)+4,x,beta,y)
mv!(y::StrideOneVector{Float64},A::Adjoint{Float64,SparseMatrixCSC{Float64,Int32}},x::StrideOneVector{Float64};
    alpha::Float64=1.,beta::Float64=0.) = (length(y) > 0 && length(x) > 0) &&
        ccall((:mkl_dcscmv,libmkl32),
              Cvoid,
              (Ref{Cchar},Ref{Int32},Ref{Int32},Ref{Float64},Ptr{Cchar},Ptr{Float64},Ptr{Int32},
               Ptr{Int32},Ptr{Int32},Ptr{Float64},Ref{Float64},Ptr{Float64}),
              't',Int32(A.parent.m),Int32(A.parent.n),alpha,"G00000",A.parent.nzval,A.parent.rowval,
              pointer(A.parent.colptr),pointer(A.parent.colptr)+4,x,beta,y)
symv!(y::StrideOneVector{Float64},A::Matrix{Float64},x::StrideOneVector{Float64}) =
    (length(y) > 0 && length(x) >0) && BLAS.symv!('l', 1., A, x, 0., y)
mv!(y::StrideOneVector{Float64},A::Matrix{Float64},x::StrideOneVector{Float64};
    alpha::Float64=1.,beta::Float64=0.) = (length(y) > 0) && BLAS.gemv!('n',alpha,A,x,beta,y)
mv!(y::StrideOneVector{Float64},A::Adjoint{Float64,Matrix{Float64}},x::StrideOneVector{Float64};
    alpha::Float64=1.,beta::Float64=0.) = (length(y) > 0) && BLAS.gemv!('t',alpha,A.parent,x,beta,y)


function findIJ(S::SparseMatrixCSC{Tv,Ti}) where {Tv,Ti}
    numnz = nnz(S)
    I = Vector{Ti}(undef,numnz)
    J = Vector{Ti}(undef,numnz)

    cnt = 1
    @inbounds for col = 1 : size(S, 2), k = getcolptr(S)[col] : (getcolptr(S)[col+1]-1)
        I[cnt] = rowvals(S)[k]
        J[cnt] = col
        cnt += 1
    end

    return I,J
end

function get_tril_to_full(csc::SparseMatrixCSC{Tv,Ti}) where {Tv,Ti<:Integer}
    cscind = SparseMatrixCSC{Int,Ti}(Symmetric(
        SparseMatrixCSC{Int,Ti}(csc.m,csc.n,csc.colptr,csc.rowval,collect(1:nnz(csc))),:L))
    return SparseMatrixCSC{Tv,Ti}(
        csc.m,csc.n,cscind.colptr,cscind.rowval,Vector{Tv}(undef,nnz(cscind))),view(csc.nzval,cscind.nzval)
end
function tril_to_full!(dense::Matrix)
    for i=1:size(dense,1)
        Threads.@threads for j=i:size(dense,2)
            @inbounds dense[i,j]=dense[j,i]
        end
    end
end

function get_get_coo_to_com(mtype)
    if mtype == :csc
        get_coo_to_com = get_coo_to_csc
    elseif mtype == :cucsc
        get_coo_to_com = get_coo_to_cucsc
    elseif mtype == :dense
        get_coo_to_com = get_coo_to_dense
    elseif mtype == :cudense
        get_coo_to_com = get_coo_to_cudense
    else
        error(LOGGER,"Linear solver input type is not supported.")
    end
end

function get_coo_to_csc(coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti <: Integer}
    map = Vector{Ti}(undef,nnz(coo))
    cscind = sparse(coo.I,coo.J,ones(Ti,nnz(coo)),coo.m,coo.n)
    cscind.nzval.= 1:nnz(cscind)
    _get_coo_to_csc(coo.I,coo.J,cscind,map)
    nzval = Vector{Tv}(undef,nnz(cscind))
    return SparseMatrixCSC{Tv,Ti}(
        coo.m,coo.n,cscind.colptr,cscind.rowval,nzval), ()->transform!(nzval,coo.V,map)
end
function _get_coo_to_csc(I,J,cscind,map)
    for i=1:length(I)
        @inbounds map[i] = cscind[I[i],J[i]]
    end
end
function transform!(vec1,vec2,map)
    vec1.=0;
    for i=1:length(map)
        @inbounds vec1[map[i]] += vec2[i]
    end
end

function get_coo_to_dense(coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer}
    dense = Matrix{Float64}(undef,coo.m,coo.n)
    return dense, ()->copyto!(dense,coo)
end

copyto!(dense::Matrix{Tv},coo::SparseMatrixCOO{Tv,Ti}) where {Tv,Ti<:Integer} = copyto!(dense,coo.I,coo.J,coo.V)
function copyto!(dense::Matrix{Tv},I,J,V) where Tv
    dense.=0
    for i=1:length(I)
        dense[I[i],J[i]]+=V[i]
    end
    return dense
end


function get_cscsy_view(csc::SparseMatrixCSC{Tv,Ti},Ix;inds=collect(1:nnz(csc))) where {Tv,Ti<:Integer}
    cscind = SparseMatrixCSC{Int,Ti}(csc.m,csc.n,csc.colptr,csc.rowval,inds)
    cscindsub = cscind[Ix,Ix]
    return SparseMatrixCSC{Tv,Ti}(
        cscindsub.m,cscindsub.n,cscindsub.colptr,
        cscindsub.rowval,Vector{Tv}(undef,nnz(cscindsub))), view(csc.nzval,cscindsub.nzval)
                                  
end
function get_csc_view(csc::SparseMatrixCSC{Tv,Ti},Ix,Jx;inds=collect(1:nnz(csc))) where {Tv,Ti<:Integer}
    cscind = Symmetric(SparseMatrixCSC{Int,Ti}(csc.m,csc.n,csc.colptr,csc.rowval,inds),:L)
    cscindsub = cscind[Ix,Jx]
    resize!(cscindsub.rowval,cscindsub.colptr[end]-1)
    resize!(cscindsub.nzval,cscindsub.colptr[end]-1)
    return SparseMatrixCSC{Tv,Ti}(
        cscindsub.m,cscindsub.n,cscindsub.colptr,
        cscindsub.rowval,Vector{Tv}(undef,nnz(cscindsub))), view(csc.nzval,cscindsub.nzval)
end
