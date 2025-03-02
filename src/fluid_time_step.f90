!-------------------------------------------------------------------------------
!          MAIN WRAPPER FOR DIFFERENT TIME MARCHING METHODS
!-------------------------------------------------------------------------------
! INPUT
! time, dt0, dt1: time, dt0=t^n - t^n-1, dt1= t^n+1-t^n
! u             work array (input value is overwritten)
! uk            velocity in F-space at time level n
! nlk           right hand side work array. holds the RHS at time level (n-1)
!               which we need for AB2. The second part of it is the work array
!               used to store the new RHS at (t)
! vort          work array (input value is overwritten)
! work          work arrays (real, "nrw" arrays)
! workc         work arrays (cmplx, "nrc" arrays)
! expvis        integrating factor(s). if dt did not change, the input value is
!               used to advance in time. otherwise, the exponential term is
!               recomputed with the new time step
! press         pressure field in x-space, WITH GHOST POINTS
! beams         the solid model datatype, which is advanced in the FSI time
!               steppers.
! scalars       passive scalars at old time level
! scalars_rhs
!-------------------------------------------------------------------------------
! OUTPUT
! u             velocity in phys space at time level (n) (the OLD level)
! uk            velocity in fourier space at the new time level (n+1)
! nlk           contains the RHS at time (n) and (n-1). in the next time step,
!               one can overwrite (n-1) and (n) becomes (n-1)
! press         pressure in x-space, if the flag use_solid_model==yes
! expvis        the integrating factor(s) which are updated if the dt changes
! vort          the vorticity at time level (n) in phys space
! beams         the solid model at the new time level
! scalars       passive scalars at new time level
!-------------------------------------------------------------------------------
subroutine FluidTimestep(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,workc,&
  expvis,press,scalars,scalars_rhs,Insect,beams)
  use mpi
  use p3dfft_wrapper
  use vars
  use solid_model
  use insect_module
  use basic_operators
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::n0,n1,it
  real(kind=pr)::t1
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)

  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect

  t1=MPI_wtime()

  ! Call fluid advancement subroutines.
  select case(iTimeMethodFluid)
  case("RK2")
    call RungeKutta2(time,it,dt0,dt1,u,uk,nlk,vort,work,&
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case("RK4")
    call RungeKutta4(time,it,dt0,dt1,u,uk,nlk,vort,work,&
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case("AB2")
    if(it == 0) then
      call euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort,work,&
      workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
    else
      call adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,&
      workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
    endif
  case ("AB2_rigid_solid")
    call AB2_rigid_solid(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,&
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case("FSI_AB2_iteration")
    call FSI_AB2_iteration(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work, &
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case("FSI_AB2_staggered")
    call FSI_AB2_staggered(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work, &
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case("FSI_AB2_semiimplicit")
    call FSI_AB2_semiimplicit(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work, &
    workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  case default
    if (root) write(*,*) "Error! iTimeMethodFluid unknown. Abort."
    call abort()
  end select

  ! compute unsteady corrections in every time step
  if(method=="fsi" .and. unst_corrections==1) then
    call cal_unst_corrections ( time, dt0, Insect )
  endif

  ! Force zero mode for mean flow
  if(method=="fsi") call set_mean_flow(uk,time)

  ! save zero mode in global variables (useless if it is fixed, but useful if dynamic)
  if(method=="fsi") call get_mean_flow(uk,uxmean,uymean,uzmean)
  ! Set the divergence of the magnetic field to zero to avoid drift.
  if(method=="mhd") call div_field_nul(uk(:,:,:,4),uk(:,:,:,5),uk(:,:,:,6))

  ! compute running average, if used. applies to FSI only
  if ((method=="fsi").and.(time_avg=="yes").and.(time>tstart_avg)) then
    if (vel_avg=="yes") then
      ! average the velocity
      uk_avg = (uk*dt1  + (time-tstart_avg)*uk_avg) / ( (time-tstart_avg)+dt1 )
    endif

    if (ekin_avg=="yes") then
      ! average kinetic energy
      e_avg = ( 0.5d0*(u(:,:,:,1)**2 + u(:,:,:,2)**2 + u(:,:,:,3)**2)*dt1  &
      + (time-tstart_avg)*e_avg ) / ( (time-tstart_avg)+dt1 )
    endif
  endif

  if(method=="fsi") then
    ! write kinetic energy to disk
    call output_kinetic_energy(time+dt1, uk)
    ! check if we did something stupid and failed
    call checknan(uk(:,:,:,1),'ukx (current time step)')
    call checknan(uk(:,:,:,2),'uky (current time step)')
  endif



  time_fluid=time_fluid + MPI_wtime() - t1
end subroutine FluidTimestep




!-------------------------------------------------------------------------------
! FSI scheme based on AB2/EE1 for the fluid, iterates coupling conditions.
! adapted from the 2D codes (V12), based on the PhD thesis of von Scheven
!-------------------------------------------------------------------------------
subroutine FSI_AB2_iteration(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,&
  workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout) :: time,dt1,dt0
  integer,intent (in) :: n0,n1,it
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  type(solid),dimension(1:nbeams),intent(inout) :: beams
  type(diptera),intent(inout)::Insect

  !-- iteration specific variables
  type(solid), dimension(1) :: beams_old
  real(kind=pr),dimension(0:ns-1) :: deltap_new, deltap_old, bpress_old_iterating
  real(kind=pr)::bruch, upsilon_new, upsilon_old, kappa2, ROC1,ROC2, norm
  real(kind=pr)::omega_old, omega_new
  type(diptera)::Insect_dummy
  integer :: inter
  logical :: iterate

  ! useful error messages
  if (use_solid_model/="yes") then
    write(*,*) "using FSI_AB2_iteration without solid model?"
    call abort()
  endif

  ! allocate extra space for velocity in Fourier space
  if (.not.allocated(uk_old)) then
    call alloccomplexnd(uk_old)
  endif
  ! we need that to compute the pressure at preliminary times
  if (.not.allocated(nlk_tmp)) then
    allocate(nlk_tmp(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq))
  endif
  ! copy velocity at time level (n)
  uk_old = uk

  ! initialize iteration variables
  inter = 0
  iterate = .true.
  deltap_new = 0.d0
  deltap_old = 0.d0
  upsilon_new = 0.d0
  upsilon_old = 0.d0
  beams_old = beams
  omega_old = 0.5d0
  omega_new = 0.5d0
  ! the passive scalar is advanced only once during the iteration process to keep the cost down.
  if(use_passive_scalar==1) compute_scalar = .true.

  ! predictor for the pressure
  beams(1)%pressure_new = beams(1)%pressure_old

  ! begin main iteration loop
  do while (iterate)
    !---------------------------------------------------------------------------
    ! create mask
    !---------------------------------------------------------------------------
    call create_mask(time, Insect_dummy, beams)

    !---------------------------------------------------------------------------
    ! advance fluid to from (n) to (n+1)
    !---------------------------------------------------------------------------
    if(use_passive_scalar==1) then
      ! advance the scalar only once when iterating.
      if (inter==0) compute_scalar = .true.
      if (inter/=0) compute_scalar = .false.
    endif

    ! start from t(n) again, except for the scalar
    uk(:,:,:,1:3) = uk_old(:,:,:,1:3)

    if(it == 0) then
      call euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort, &
      work,workc,expvis,press,scalars,scalars_rhs,inter,Insect,beams)
    else
      call adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort, &
      work,workc,expvis,press,scalars,scalars_rhs,inter,Insect,beams)
    endif

    !---------------------------------------------------------------------------
    ! get forces at new time level
    !---------------------------------------------------------------------------
    bpress_old_iterating = beams(1)%pressure_new(0:ns-1) ! exit of the old iteration
    call pressure_given_uk(time,u,uk,nlk_tmp,vort,work,workc,press)
    call get_surface_pressure_jump (time, beams(1), press, timelevel="new")

    !---------------------------------------------------------------------------
    ! relaxation
    !---------------------------------------------------------------------------
    ! whats the diff betw new interp press and last iteration's step?
    deltap_new = bpress_old_iterating - beams(1)%pressure_new(0:ns-1)
    if (inter==0) then
      upsilon_new = 0.0d0
      ! von scheven normalizes with the explicit scheme, which is what we do now
      norm = sqrt(sum((beams(1)%pressure_new(0:ns-1)-beams(1)%pressure_old(0:ns-1))**2))
    else
      bruch = (sum((deltap_old-deltap_new)*deltap_new)) &
      / (sum((deltap_old-deltap_new)**2))
      upsilon_new = upsilon_old + (upsilon_old-1.d0) * bruch
    endif
    kappa2 = 1.d0 - upsilon_new
    ! new iteration pressure is old one plus star
    beams(1)%pressure_new(0:ns-1) = (1.d0-kappa2)*bpress_old_iterating(0:ns-1) &
    + kappa2*beams(1)%pressure_new(0:ns-1)

    !---------------------------------------------------------------------------
    ! advance solid model from (n) to (n+1)
    !---------------------------------------------------------------------------
    beams_old(1)%pressure_new = beams(1)%pressure_new
    beams = beams_old ! advance from timelevel n
    call SolidSolverWrapper( time, dt1, beams )

    !---------------------------------------------------------------------------
    ! convergence test
    !---------------------------------------------------------------------------
    ROC1 = dsqrt( sum((beams(1)%pressure_new(0:ns-1)-bpress_old_iterating)**2)) / dble(ns)
    ROC2 = dsqrt( sum((beams(1)%pressure_new(0:ns-1)-bpress_old_iterating)**2)) / norm
    if (((ROC2<1.0d-3).or.(inter==100)).or.(it<2)) then
      iterate = .false.
    endif

    ! iterate
    deltap_old = deltap_new
    upsilon_old = upsilon_new
    inter = inter + 1
    omega_old=omega_new

    if (root) then
      open (15, file='iterations_log.t',status='unknown',position='append')
      write(15,'("t=",es12.4," dt=",es12.4," inter=",i3," ROC=",es15.8,&
      &" ROC2=",es15.8," p_end=",es15.8," kappa2=",es15.8)') &
      time,dt1,inter,ROC1,ROC2,beams(1)%pressure_new(ns-1), kappa2
      close (15)
    endif
  enddo

  ! dump iteration information to disk
  if (root) then
    open (15, file='iterations.t',status='unknown',position='append')
    write(15,'(2(es15.8,1x),i3,2(es15.8,1x))') time, dt1, inter, ROC1, ROC2
    close(15)

    ! mark end of time step
    open (15, file='iterations_log.t',status='unknown',position='append')
    write(15,'("---")')
    close(15)
  endif

  ! free work array
  !   deallocate (uk_old,nlk_tmp)
end subroutine FSI_AB2_iteration



!-------------------------------------------------------------------------------
! explicit FSi scheme, cheapest and simplest possible. Advances first the fluid
! then the solid, and computes the solid with the pressure from the old time
! level (n), avoiding computing it at the new level, which saves about 50%
! with respect to FSI_AB2_semiimplicit. The latter may however be more accurat
! or stable.
!-------------------------------------------------------------------------------
subroutine FSI_AB2_staggered(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,&
  workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout) :: time,dt1,dt0
  integer,intent (in) :: n0,n1,it
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  type(solid),dimension(1:nbeams),intent(inout) :: beams
  type(diptera),intent(inout)::Insect

  ! useful error messages
  if (use_solid_model/="yes") then
    write(*,*) "using FSI_AB2_staggered without solid model?"
    call abort()
  endif

  !---------------------------------------------------------------------------
  ! create mask
  !---------------------------------------------------------------------------
  call create_mask(time,Insect, beams(1))

  !---------------------------------------------------------------------------
  ! advance fluid to from (n) to (n+1)
  !---------------------------------------------------------------------------
  if(it == 0) then
    call euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  else
    call adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  endif

  !---------------------------------------------------------------------------
  ! get forces at old time level, since press is at t^n.
  ! save to both beam%pressure_new and beam%pressure_old
  !---------------------------------------------------------------------------
  call get_surface_pressure_jump (time, beams(1), press)

  !---------------------------------------------------------------------------
  ! advance solid model from (n) to (n+1)
  !---------------------------------------------------------------------------
  call SolidSolverWrapper( time, dt1, beams )

end subroutine FSI_AB2_staggered


!-------------------------------------------------------------------------------
! semi implicit explicit staggered scheme for FSI simulations, uses AB2 for the
! fluid (or euler on startup) and evaluates the pressure at both old and new
! time level. since computing the pressure is almost as expensive as doing a full
! fluid time step, this scheme is twice as expensive as its explicit counterpart
! FSI_AB2_staggered.
!-------------------------------------------------------------------------------
subroutine FSI_AB2_semiimplicit(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,&
  work,workc,expvis,press,scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout) :: time,dt1,dt0
  integer,intent (in) :: n0,n1,it
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  type(solid),dimension(1:nbeams),intent(inout) :: beams
  type(diptera),intent(inout)::Insect
  type(diptera)::Insect_dummy

  ! useful error messages
  if (use_solid_model/="yes") then
    write(*,*) "using FSI_AB2_staggered without solid model?"
    call abort()
  endif

  !---------------------------------------------------------------------------
  ! create mask
  !---------------------------------------------------------------------------
  call create_mask(time,Insect_dummy, beams(1))

  !---------------------------------------------------------------------------
  ! advance fluid to from (n) to (n+1)
  !---------------------------------------------------------------------------
  if(it == 0) then
    call euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  else
    call adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  endif

  !---------------------------------------------------------------------------
  ! get forces at old/new time level
  !---------------------------------------------------------------------------
  ! TODO: do we need that? not for BDF I think
  call get_surface_pressure_jump (time, beams(1), press, timelevel="old")
  ! we can overwrite NLK(n1) since this is the one overwritten in the next call
  call pressure_given_uk(time,u,uk,nlk(:,:,:,:,n1),vort,work,workc,press)
  call get_surface_pressure_jump (time, beams(1), press, timelevel="new")

  !---------------------------------------------------------------------------
  ! advance solid model from (n) to (n+1)
  !---------------------------------------------------------------------------
  call SolidSolverWrapper( time, dt1, beams )

end subroutine FSI_AB2_semiimplicit





!-------------------------------------------------------------------------------
! FIXME: add documentation: which arguments are used for what?
subroutine rungekutta2(time,it,dt0,dt1,u,uk,nlk,vort,work,workc,expvis,press,&
           scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::it
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  integer::i
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect

  if ((use_passive_scalar==1).and.(mpirank==1)) then
    write(*,*) "RK2 is not equipped for passive scalars..."
    call abort()
  endif

  !-- Calculate fourier coeffs of nonlinear rhs and forcing (for the euler step)
  call cal_nlk(time,it,nlk(:,:,:,:,0),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)
  call adjust_dt(time,u,dt1)

  !-- multiply the RHS with the viscosity, first the velocity
  do i=1,3
    nlk(:,:,:,i,0)=nlk(:,:,:,i,0)*expvis(:,:,:,1)
  enddo

  !-- then, if present, the B-field
  if (method=="mhd") then
    do i=4,6
      nlk(:,:,:,i,0)=nlk(:,:,:,i,0)*expvis(:,:,:,2)
    enddo
  endif

  !-- Compute integrating factor, only done if necessary (i.e. time step
  !-- has changed)
  if (dt1 .ne. dt0) then
    call cal_vis(dt1,expvis)
  endif

  !-- Do the actual euler step. note nlk is already multiplied by vis
  do i=1,3
    !-- advance fluid vecolity
    uk(:,:,:,i)=(uk(:,:,:,i)*expvis(:,:,:,1) + dt1*nlk(:,:,:,i,0))
  enddo

  if (method=="mhd") then
    do i=4,6
      !-- advance B-field
      uk(:,:,:,i)=(uk(:,:,:,i)*expvis(:,:,:,2) + dt1*nlk(:,:,:,i,0))
    enddo
  endif

  !-- RHS using the euler velocity
  call cal_nlk(time,it,nlk(:,:,:,:,1),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)

  ! do the actual time step. note the minus sign.in the original formulation, it
  ! reads: u^n+1=u^n + dt/2*( N(u^n)*vis + N(u_euler) )
  ! but we don't want to save u_euler seperately, we want to overwrite
  ! u^n with it!  so the formulation reads
  ! u^n+1=u_euler - dt*N(u^n)*vis + dt/2*( N(u^n)*vis + N(u_euler) )
  !-- which yields simply
  !-- u^n+1=u_euler + dt/2*( -N(u^n)*vis + N(u_euler) )
  do i=1,nd
    !-- advance all nd fields
    uk(:,:,:,i)=uk(:,:,:,i) +0.5d0*dt1*(-nlk(:,:,:,i,0) + nlk(:,:,:,i,1) )
  enddo
end subroutine rungekutta2


! RK4 scheme with EXPLICIT diffusion
subroutine rungekutta4(time,it,dt0,dt1,u,uk,nlk,vort,work,workc,expvis,press,&
           scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  use basic_operators
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::it
  complex(kind=pr),intent(inout):: uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect
  integer::i

  if ((use_passive_scalar==1).and.(mpirank==0)) then
    write(*,*) "RK4 is not equipped for passive scalars..."
    call abort()
  endif

  if ((method=="mhd").and.(mpirank==0)) then
    write(*,*) "RK4 is not equipped for MHD..."
    call abort()
  endif

  if ((mpirank==0).and.(it==1)) then
    write(*,'("RungeKutta treats diffusion explicitly, and this is the restriction: dt<",es12.4)') &
    0.5d0*min(dx,dy,dz)**2 / nu
  endif
  ! copy velocity at old time level
  nlk(:,:,:,:,4) = uk

  !-- FIRST runge kutta step
  call cal_nlk(time,it,nlk(:,:,:,:,0),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)
  call dealias(nlk(:,:,:,:,0))
  call adjust_dt(time,u,dt1)


  !-- SECOND runge kutta step
  uk = nlk(:,:,:,:,4) + 0.5d0*dt1*nlk(:,:,:,:,0)
  call cal_nlk(time+0.5d0*dt1,it,nlk(:,:,:,:,1),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)
  call dealias(nlk(:,:,:,:,1))

  !--THIRD runge kutta step
  uk = nlk(:,:,:,:,4) + 0.5d0*dt1*nlk(:,:,:,:,1)
  call cal_nlk(time+0.5d0*dt1,it,nlk(:,:,:,:,2),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)
  call dealias(nlk(:,:,:,:,2))

  !-- FOURTH runge kutta step
  uk = nlk(:,:,:,:,4) + dt1*nlk(:,:,:,:,2)
  call cal_nlk(time+dt1,it,nlk(:,:,:,:,3),uk,u,vort,work,workc,press,scalars,scalars_rhs,Insect,beams)
  call dealias(nlk(:,:,:,:,3))

  !-- FINAL step
  uk = nlk(:,:,:,:,4) + (dt1/6.d0) * ( nlk(:,:,:,:,0) + 2.d0*nlk(:,:,:,:,1) + &
  2.d0*nlk(:,:,:,:,2) + nlk(:,:,:,:,3) )

  call dealias(uk)

end subroutine rungekutta4


! Note this is not an optimized Euler. It only does things we need for AB2.
subroutine euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort,work,workc,&
  expvis,press,scalars,scalars_rhs,iter,Insect,beams)
  use mpi
  use p3dfft_wrapper
  use vars
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::n0,it,iter
  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::&
  nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  ! the workc array is not always allocated, ensure allocation before using
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect
  real(kind=pr)::t1
  integer::i

  !-- Calculate fourier coeffs of nonlinear rhs and forcing
  call cal_nlk(time,it,nlk(:,:,:,:,n0),uk,u,vort,work,workc,press,&
               scalars,scalars_rhs(:,:,:,:,n0),Insect,beams)
  call adjust_dt(time,u,dt1)

  !-- Compute integrating factor, if necesssary
  if (dt1 .ne. dt0) then
    call cal_vis(dt1,expvis)
  endif

  !-- Advance in time, multiply by the integrating factor
  do i=1,3
    !-- advance fluid velocity
    uk(:,:,:,i)=(uk(:,:,:,i) + dt1*nlk(:,:,:,i,n0))*expvis(:,:,:,1)
    ! multiply RHS with integrating factor
    if (iter==0) then
      ! if this routine is called several times in one time step (iterations), do
      ! multiply the old rhs only once with expvis (hence skip if iter=1)
      nlk(:,:,:,i,n0)=nlk(:,:,:,i,n0)*expvis(:,:,:,1)
    endif
  enddo

  if (method=="mhd") then
    do i=4,6
      !-- advance B-field
      uk(:,:,:,i)=(uk(:,:,:,i) + dt1*nlk(:,:,:,i,n0))*expvis(:,:,:,2)
      ! multiply RHS with integrating factor
      if (iter==0) then
        ! if this routine is called several times in one time step (iterations), do
        ! multiply the old rhs only once with expvis
        nlk(:,:,:,i,n0)=nlk(:,:,:,i,n0)*expvis(:,:,:,2)
      endif
    enddo
  endif

  if ((method=="fsi").and.(use_passive_scalar==1).and.(compute_scalar)) then
    !-- advance passive scalar (no integrating factor here!!)
    t1 = MPI_wtime()
    scalars = scalars + dt1*scalars_rhs(:,:,:,:,n0)
    time_scalar = time_scalar + MPI_wtime() - t1
  endif

  if (mpirank ==0) write(*,'(A)') "*** info: did startup euler............"
end subroutine euler_startup


! FIXME: add documentation: which arguments are used for what?
subroutine adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,workc,&
  expvis,press,scalars,scalars_rhs,iter,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::n0,n1,it,iter
  complex(kind=pr),intent(inout) ::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::&
  nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  ! the workc array is not always allocated, ensure allocation before using
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect
  real(kind=pr)::b10,b11,t1
  integer::i

  !-- Calculate fourier coeffs of nonlinear rhs and forcing
  call cal_nlk(time,it,nlk(:,:,:,:,n0),uk,u,vort,work,workc,press,&
               scalars,scalars_rhs(:,:,:,:,n0),Insect,beams)
  call adjust_dt(time,u,dt1)
  if (dt1>tmax-time) dt1=tmax-time

  !-- Calculate velocity at new time step
  !-- (2nd order Adams-Bashforth with exact integration of diffusion term)
  b10=dt1/dt0*(0.5d0*dt1 + dt0)
  b11=-0.5d0*dt1*dt1/dt0

  !-- compute integrating factor, if necesssary
  if (dt1 .ne. dt0) then
    call cal_vis(dt1,expvis)
  endif

  !-- Advance in time, multiply by the integrating factor
  do i=1,3
    ! advance fluid velocity
    uk(:,:,:,i)=(uk(:,:,:,i)+b10*nlk(:,:,:,i,n0)+b11*nlk(:,:,:,i,n1))*expvis(:,:,:,1)
    ! multiply RHS with integrating factor
    if (iter==0) then
      ! if this routine is called several times in one time step (iterations), do
      ! multiply the old rhs only once with expvis (hence skip if iter=1)
      nlk(:,:,:,i,n0)=nlk(:,:,:,i,n0)*expvis(:,:,:,1)
    endif
  enddo

  !-- advance B-field in time
  if (method=="mhd") then
    do i=4,6
      ! advance B-field
      uk(:,:,:,i)=(uk(:,:,:,i)+b10*nlk(:,:,:,i,n0)+b11*nlk(:,:,:,i,n1))*expvis(:,:,:,2)
      ! multiply RHS with integrating factor
      if (iter==0) then
        ! if this routine is called several times in one time step (iterations), do
        ! multiply the old rhs only once with expvis
        nlk(:,:,:,i,n0)=nlk(:,:,:,i,n0)*expvis(:,:,:,2)
      endif
    enddo
  endif

  !-- advance passive scalar in time
  if ((method=="fsi").and.(use_passive_scalar==1).and.(compute_scalar)) then
    !-- advance passive scalar (no integrating factor here!!)
    t1 = MPI_wtime()
    scalars = scalars + b10*scalars_rhs(:,:,:,:,n0) + b11*scalars_rhs(:,:,:,:,n1)
    time_scalar = time_scalar + MPI_wtime() - t1
  endif
end subroutine adamsbashforth


! time stepper for rigid soldi FSI, for example insect takeoff or falling sphere
subroutine AB2_rigid_solid(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort,work,workc,&
  expvis,press,scalars,scalars_rhs,Insect,beams)
  use mpi
  use vars
  use p3dfft_wrapper
  use solid_model
  use insect_module
  implicit none

  real(kind=pr),intent(inout)::time,dt1,dt0
  integer,intent(in)::n0,n1,it
  complex(kind=pr),intent(inout) ::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  complex(kind=pr),intent(inout)::&
  nlk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq,0:nrhs-1)
  ! the workc array is not always allocated, ensure allocation before using
  complex(kind=pr),intent(inout)::workc(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:ncw)
  real(kind=pr),intent(inout)::work(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nrw)
  real(kind=pr),intent(inout)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::vort(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  real(kind=pr),intent(inout)::expvis(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:nf)
  ! pressure array. this is with ghost points for interpolation
  real(kind=pr),intent(inout)::press(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3))
  real(kind=pr),intent(inout)::scalars(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars)
  real(kind=pr),intent(inout)::scalars_rhs(ga(1):gb(1),ga(2):gb(2),ga(3):gb(3),1:n_scalars,0:nrhs-1)
  real(kind=pr)::b10,b11,t1
  integer::i
  type(solid),dimension(1:nbeams),intent(inout)::beams
  type(diptera),intent(inout)::Insect

  if ((Insect%BodyMotion/="free_flight").and.(root)) then
    write(*,*) "ERROR AB2_rigid_solid and flag SolidDyn%idynamics/=1"
    write(*,*) "it makes no sense to do that, change iFluidTimeMethod=AB2"
    call abort()
  endif

  if ((method/="fsi").and.(mpirank==0)) then
    write(*,*) "AB2_rigid_solid is an FSI method and not suitable for MHD"
    call abort()
  endif

  !---------------------------------------------------------------------------
  ! advance fluid to from (n) to (n+1)
  !---------------------------------------------------------------------------
  if(it == 0) then
    call euler_startup(time,it,dt0,dt1,n0,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  else
    call adamsbashforth(time,it,dt0,dt1,n0,n1,u,uk,nlk,vort, &
    work,workc,expvis,press,scalars,scalars_rhs,0,Insect,beams)
  endif

  !---------------------------------------------------------------------------
  ! compute hydrodynamic forces for rigid solid solver
  !---------------------------------------------------------------------------
  t1 = MPI_wtime()
  if (unst_corrections ==1) then
    call cal_unst_corrections ( time, dt0, Insect )
  endif
  call cal_drag ( time, u, Insect ) ! note u is OLD time level
  time_drag = time_drag + MPI_wtime() - t1

  !---------------------------------------------------------------------------
  ! solve Newton's second law
  !---------------------------------------------------------------------------
  ! note dt0 is OLD time step t(n)-t(n-1)
  ! advance in time ODEs that describe rigid solids
  call rigid_solid_time_step(time,dt0,dt1,it,Insect)


end subroutine AB2_rigid_solid

!-------------------------------------------------------------------------------
! Set the time step based on the CFL condition and penalization
! stability contidion. The following limitations exist:
! 1 - CFL condition
! 2 - fixed time step dt_fixed, ignoring all other constraints, if set in params
! 3 - penalization restriction dt<eps
! 4 - maximum time step dt_max, if set in params
! 5 - dt is smaller than tsave and tintegral
!-------------------------------------------------------------------------------
subroutine adjust_dt(time,u,dt1)
  use vars
  use mpi
  use basic_operators
  implicit none

  real(kind=pr), intent(in) :: time
  real(kind=pr), intent(in)::u(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  integer::mpicode
  real(kind=pr), intent(out)::dt1
  real(kind=pr)::umax,t , t1,t2

  if (dt_fixed>0.0d0) then
    !-- fix the time step no matter what. the result may be unstable.
    dt1=dt_fixed
  else
    !-- Determine the maximum velocity/magnetic field value
    if (method=="mhd") then
      !-- MHD needs to respect CFL for magnetic field as well
      umax = max( field_max_magnitude(u(:,:,:,1:3)), field_max_magnitude(u(:,:,:,4:6)) )
    else
      !-- FSI runs just need to respect CFL for velocity
      umax = field_max_magnitude(u(:,:,:,1:3))
    endif

    !-- Adjust time step at 0th process
    if(mpirank == 0) then
      if(is_nan(umax)) then
        write(*,*) "Evolved field contains a NAN: aborting run."
        call abort()
      endif

      if(umax>=1.0d3) then
        write(*,*) "Umax is very big, surely this is an error, ", umax
        call abort()
      endif
      !-- Impose the CFL condition.
      if (umax >= 1.0d-8) then
        if (nx==1) then
          ! 2D case
          dt1=min(dy,dz)*cfl/umax
        else
          ! 3D case
          dt1=min(dx,dy,dz)*cfl/umax
        endif
      else
        !-- umax is very very small
        dt1=1.0d-3
      endif

      !-- Round the time-step to one digit to reduce calls of cal_vis
      call truncate(dt1)

      !-- impose max dt, if specified
      if (dt_max>0.d0) dt1=min(dt1,dt_max)
      !-- Impose penalty stability condition: dt cannot be larger than eps
      if (iPenalization > 0) dt1=min(0.99d0*eps,dt1)

      !-- RungeKutta4 treats diffusive terms explicitly, so there is a condition
      !   for the viscosity as well.
      if (iTimeMethodFluid=="RK4") then
        dt1=min( dt1, 0.5d0*min(dx,dy,dz)**2 / nu )
      endif

      !*************************************************************************
      ! we respect all necessary restrictions, the following ones are optional
      !*************************************************************************
      if (intelligent_dt=="yes") then
        ! intelligent dt means we make sure not to jump past multiples of tsave
        ! tend tintegral tslice.
        ! The AB2 scheme may have problems if the new time step is much smaller
        ! then the new one, so it may be wiser not to use it in that case (it has
        ! not been tested)
        if (time>=tsave_first) then
          ! Don't jump past save-points: if the time-step is larger than
          ! the time interval between outputs, decrease the time-step.
          dt1 = min(dt1,0.98d0*tsave)
          t = dble(ceiling(time/tsave))*tsave
          if ((time+dt1>t).and.(abs(time-t)>=1.0d-6)) then
            dt1=t-time
          endif
        endif

        ! Don't jump past save-points: if the time-step is larger than
        ! the time interval between outputs, decrease the time-step.
        dt1 = min(dt1,0.98d0*tintegral)
        t = dble(ceiling(time/tintegral))*tintegral
        if ((time+dt1>t).and.(abs(time-t)>=1.0d-6)) then
          dt1=t-time
        endif

        if (time>=tslice_first) then
          ! Don't jump past save-points: if the time-step is larger than
          ! the time interval between outputs, decrease the time-step.
          dt1 = min(dt1,0.98d0*tslice)
          t = dble(ceiling(time/tslice))*tslice
          if ((time+dt1>t).and.(abs(time-t)>=1.0d-6)) then
            dt1=t-time
          endif
        endif

        t = tmax
        if ((time+dt1>t).and.(abs(time-t)>=1.0d-6)) then
          dt1 = tmax-time
        endif
      endif
    endif

    if(mpirank==0) then
      open(14,file='dt.t',status='unknown',position='append')
      write (14,'(5(g15.8,1x))') time, dt1, &
      dt1*umax/min(dx,dy,dz),& ! currently valid CFL number
      dt1*nu/min(dx,dy,dz)**2, & ! coefficient in front of viscous stability (below 0.5 for RK4)
      dt1/eps ! penalization limit
      close(14)
    endif
    ! Broadcast time step to all processes
    call MPI_BCAST(dt1,1,MPI_DOUBLE_PRECISION,0,MPI_COMM_WORLD,mpicode)
  endif

end subroutine adjust_dt


!-------------------------------------------------------------------------------
! Truncate = round a real number to one significant digit, i.e. from 1.246262e-2
! to 1.2e-2. This slightly modifies the CFL condition (if the time step is
! dictated by CFL and not by penalization), but allows to keep the time step
! constant over more time steps, which is more efficient.
!-------------------------------------------------------------------------------
subroutine truncate(a)
  use vars
  implicit none

  real(kind=pr),intent(inout)::a
  character(len=7)::str

  write (str,'(es7.1)') a
  read (str,*) a
end subroutine truncate


!-------------------------------------------------------------------------------
! Force zero mode for mean flow
!-------------------------------------------------------------------------------
subroutine set_mean_flow(uk,time)
  use mpi
  use vars
  implicit none

  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  real(kind=pr),intent(inout)::time

  ! Force zero mode for mean flow
  ! TODO: this might not always select the proper mode; it could be
  ! better to determine if 0 is between ca(i) and cb(i) for i=1,2,3
  if (ca(1) == 0 .and. ca(2) == 0 .and. ca(3) == 0) then
    if (iMeanFlow_x=="fixed") uk(0,0,0,1)=Uxmean
    if (iMeanFlow_y=="fixed") uk(0,0,0,2)=Uymean
    if (iMeanFlow_z=="fixed") uk(0,0,0,3)=Uzmean
  endif
end subroutine set_mean_flow
!-------------------------------------------------------------------------------
! return zero mode for mean flow
!-------------------------------------------------------------------------------
subroutine get_mean_flow(uk,u1,u2,u3)
  use mpi
  use vars
  implicit none

  complex(kind=pr),intent(inout)::uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  real(kind=pr),intent(out)::u1,u2,u3
  real(kind=pr)::u1l,u2l,u3l
  integer :: mpicode

  u1l = 0.d0
  u2l = 0.d0
  u3l = 0.d0

  ! Force zero mode for mean flow
  ! TODO: this might not always select the proper mode; it could be
  ! better to determine if 0 is between ca(i) and cb(i) for i=1,2,3
  if (ca(1) == 0 .and. ca(2) == 0 .and. ca(3) == 0) then
    u1l=real(uk(0,0,0,1))
    u2l=real(uk(0,0,0,2))
    u3l=real(uk(0,0,0,3))
  endif

  call MPI_ALLREDUCE ( u1l,u1,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode)
  call MPI_ALLREDUCE ( u2l,u2,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode)
  call MPI_ALLREDUCE ( u3l,u3,1,MPI_DOUBLE_PRECISION,MPI_SUM,MPI_COMM_WORLD,mpicode)
end subroutine get_mean_flow




!-------------------------------------------------------------------------------
! write total kinetic energy to a small text file
! This operation is NOT in integrals.f90, since it is (almost) for free and can
! be done in every time step.
! Integration is performed in Fourier space using parsevals identity, output is
! written to ekin.t directly
!-------------------------------------------------------------------------------
subroutine output_kinetic_energy(time, uk)
  use vars
  use helpers
  implicit none
  real(kind=pr), intent(in) :: time
  complex(kind=pr),intent(inout) :: uk(ca(1):cb(1),ca(2):cb(2),ca(3):cb(3),1:neq)
  integer :: ix,iy,iz
  real(kind=pr) :: E, e1

  ! compute total kinetic energy (including the solid domain) in Fourier space
  ! using Parseval's identity
  e1 = 0.d0
  do iz=ca(1),cb(1)
    do iy=ca(2),cb(2)
      do ix=ca(3),cb(3)
        if ( ix==0 .or. ix==nx/2 ) then
          ! note zero mode and highest wavenumber is special
          e1=e1+dble(real(uk(iz,iy,ix,1))**2+aimag(uk(iz,iy,ix,1))**2)/2. &
          +dble(real(uk(iz,iy,ix,2))**2+aimag(uk(iz,iy,ix,2))**2)/2. &
          +dble(real(uk(iz,iy,ix,3))**2+aimag(uk(iz,iy,ix,3))**2)/2.
        else
          e1=e1+dble(real(uk(iz,iy,ix,1))**2+aimag(uk(iz,iy,ix,1))**2) &
          +dble(real(uk(iz,iy,ix,2))**2+aimag(uk(iz,iy,ix,2))**2) &
          +dble(real(uk(iz,iy,ix,3))**2+aimag(uk(iz,iy,ix,3))**2)
        endif
      enddo
    enddo
  enddo

  ! note the scaling factor for parsevals identity
  E = mpisum(e1)*xl*yl*zl

  if (root) then
    open(14,file='ekin.t',status='unknown',position='append')
    write (14,'(2(g15.8,1x))') time, E
    close(14)
  endif

end subroutine output_kinetic_energy
