! FSI wrapper for different (possibly time-dependend) mask functions
subroutine create_mask_fsi (time, Insect, beams )
  use mpi
  use vars
  use solid_model
  use insect_module
  use turbulent_inlet_module
  use penalization ! mask array etc
  implicit none
  real(kind=pr), intent(in) :: time
  type(solid),dimension(1:nBeams), intent(inout) :: beams
  type(diptera),intent(inout)::Insect
  logical, save :: mask_already_read = .false.

  !-------------------------------------------------------------
  ! create obstacle mask
  !-------------------------------------------------------------
  ! do not create any mask when not using penalization
  if (iPenalization==1) then
    ! Actual mask functions:
    select case (iMask)
    case ("floor_yz","floor_zy","flooryz","floorzy")
      call Draw_floor_yz()
    case ("sphere","Sphere")
      call Draw_Sphere()
    case ("cylinder","cylinder_x")
      call Draw_cylinder_x()
    case ("moving_cylinder","moving_cylinder_x")
      call Draw_moving_cylinder_x(time)
    case ("romain_open_cavity")
      call romain_open_cavity()
    case ("Flapper")
      call Flapper (time)
    case ("turek_wan")
      call turek_wan (time)
    case ("Insect","insect")
      call Draw_Insect ( time, Insect, mask, mask_color, us)
    case("Flexibility")
      call Draw_flexible_plate(time, beams(1))
    case ("plate","Plate")
      call Draw_Plate (time) ! 2d plate, etc (Dmitry, 25 Oct 2013)
    case ("noncircular_cylinder")
      call noncircular_cylinder()
    case ("couette")
      call taylor_couette()
    case("none","empty","no")
      ! in this case, no extra mask is set, but you might have e.g. the turbulent
      ! inlet or channel walls.
    case default
      ! is this case, we read the entire mask from a hdf5 file. Note the mask is not
      ! time dependent; it is read only a single time. we allow it to have constant
      ! non-zero, homogeneous us (solid velocity)
      ! check if the string begins with from_file::
      if ( iMask(1:11) == "from_file::" ) then
        ! did we already read from file?
        if (mask_already_read .eqv. .false.) then
          ! no -> read now and skip in the future
          mask_already_read = .true.
          if (root) then
            write(*,*) "reading mask from file "//iMask(12:strlen)
            write(*,*) "solid velocity field will be ", us_fixed
          endif
          call Read_Single_File( iMask(12:strlen), mask )
          ! impose homogeneous, time-constant solid velocity. the value of us_fixed
          ! can be set in the parameter file
          us(:,:,:,1) = us_fixed(1)
          us(:,:,:,2) = us_fixed(2)
          us(:,:,:,3) = us_fixed(3)
        else
          ! since we divide by eps later, in the main wrapper for mask, we multiply
          ! here first..
          mask = mask * eps
        endif
      else
        ! no known case...
        write (*,*) "iMask="//iMask//" not properly set; stopping."
        call abort()
      endif
    end select
  endif

  !-------------------------------------------------------------
  ! add cavity / channel / inlet mask
  ! The following mask functions are additional, i.e. they are added to existing
  ! mask functions. This way, one can for example compute a sphere in a channel
  ! or an insect in a turbulent inlet.
  !-------------------------------------------------------------
  ! if desired, add cavity mask surrounding the domain
  if ((iCavity/="no").and.(iPenalization==1)) then
    call Add_Cavity ()
  endif

  ! if desired, add channel mask
  if ((iChannel/="no").and.(iPenalization==1)) then
    call Add_Channel ()
  endif

  ! set turbulent inflow condition
  if ((use_turbulent_inlet=="yes").and.(iPenalization==1)) then
    call turbulent_inlet( time )
  endif

end subroutine create_mask_fsi



subroutine update_us_fsi(ub)
  use vars
  implicit none
  real(kind=pr),intent(in)::ub(ra(1):rb(1),ra(2):rb(2),ra(3):rb(3),1:nd)
  ! this is a stub in the FSI case since we always create the mask and the solid
  ! velocity field simultaneously
end subroutine update_us_fsi


! this routine draws a rigid flapping plate, that is infinite in the x-direction
! and rotates around the x0-axis by the angle alpha.
subroutine Flapper (time)
  use mpi
  use penalization ! mask array etc
  use vars
  implicit none

  real(kind=pr), intent(in) :: time
  integer :: iy,iz,ix
  real (kind=pr) :: R, alpha_t, un, alpha_max
  real (kind=pr) :: x,y,z,ys,zs, alpha,L,H,W, tmp1, N, tmp2
  real (kind=pr) :: safety, smoothing, f0

  ! reset everything
  mask = 0.d0
  mask_color = 0
  us = 0.d0

  ! motion protocoll (pitching around the x-axis with point y0,z0)
  f0 = 1.d0
  alpha_max = deg2rad(14.d0)
  alpha   =              alpha_max*dsin(2.d0*pi*f0*time)
  alpha_t = (2.d0*pi*f0)*alpha_max*dcos(2.d0*pi*f0*time)

  ! length of plate
  L = 1.d0
  ! half the plate thickness
  H = 2.0d0*dy
  ! width of plate (Aspect ratio)
  W = 0.54d0
  ! smoothing coefficient
  N = 1.5d0

  if (nx==1) then
    smoothing = N*max(dy,dz)
    safety = 2.d0*N*max(dy,dz)+H
  else
    smoothing = N*max(dx,dy,dz)
    safety = 2.d0*N*max(dx,dy,dz)+H
  endif

  do iz = ra(3), rb(3)
   do iy = ra(2), rb(2)
    do ix = ra(1), rb(1)
      x = dble(ix)*dx - x0
      if (nx==1) x=0.d0
      y = dble(iy)*dy - y0
      z = dble(iz)*dz - z0

      ! transformed
      ys =  dcos(alpha)*y + dsin(alpha)*z
      zs = -dsin(alpha)*y + dcos(alpha)*z

      if ( (ys>=0.d0) .and. (ys<=L) )  then
        if ( (zs>=-H-safety) .and. (zs<=H+safety) )  then
          if (( (x>=-0.5d0*W-safety) .and. (x<=0.5d0*W+safety) ) .or. (nx==1))  then
            call SmoothStep (tmp1, abs(zs), H, smoothing)

            if (nx/=1) then
              call SmoothStep (tmp2, abs(x), 0.5d0*W, smoothing)
            else
              tmp2=1.d0
            endif
            mask(ix,iy,iz) = tmp1*tmp2

            ! assign color "1" where >0 indicates something "useful"
            if (mask(ix,iy,iz) > 1.0d-12) then
              mask_color(ix,iy,iz) = 1
              R = dsqrt( y**2 + z**2  )
              ! normal velocity
              un = R*alpha_t
              ! transform to fixed coordinate system
              us(:,iy,iz,2) = -dsin(alpha)*un
              us(:,iy,iz,3) = +dcos(alpha)*un
            endif
          endif
        endif
      endif

    enddo
   enddo
  enddo

  ! draw the endpoints
  do iz = ra(3), rb(3)
   do iy = ra(2), rb(2)
    do ix = ra(1), rb(1)
        x = dble(ix)*dx - x0
        if (nx==1) x=0.d0
        y = dble(iy)*dy - y0
        z = dble(iz)*dz - z0

        ! leading edge (fixed endpoint)
        if ( ((y>=-15.d0*dy).and.(y<=+15.d0*dy)) .and.((z>=-15.d0*dz).and.(z<=+15.d0*dz))  )then
           R = dsqrt( y**2 + z**2 )
           call SmoothStep (tmp1, R, H, smoothing)
           if (nx/=1) then
             call SmoothStep (tmp2, abs(x), 0.5d0*W, smoothing)
           else
             tmp2=1.d0
           endif

           ! overwrite if new value is larger
           if (mask(ix,iy,iz)<tmp1*tmp2) then
              mask(ix,iy,iz) = tmp1*tmp2
              ! assign color "1" where >0 indicates something "useful"
              if (mask(ix,iy,iz) > 1.0e-12) then
                mask_color(:,iy,iz) = 1
                ! velocity (remember: rotation around x0,y0,z0)
                y = dble(iy)*dy - y0
                z = dble(iz)*dz - z0
                R = dsqrt( y**2 + z**2  )
                un = R*alpha_t
                us(ix,iy,iz,2) = -dsin(alpha)*un
                us(ix,iy,iz,3) = +dcos(alpha)*un
              endif
           endif
        endif

        ! trailing edge (moving endpoint)
        x = dble(ix)*dx - x0
        if (nx==1) x=0.d0
        y = dble(iy)*dy - (y0 + L*dcos(alpha))
        z = dble(iz)*dz - (z0 + L*dsin(alpha))

        if ( ((y>=-15.d0*dy).and.(y<=+15.d0*dy)) .and.((z>=-15.d0*dz).and.(z<=+15.d0*dz))  )then
           R = dsqrt( y**2 + z**2 )
           call SmoothStep (tmp1, R, H, smoothing)
           if (nx/=1) then
             call SmoothStep (tmp2, abs(x), 0.5d0*W, smoothing)
           else
             tmp2=1.d0
           endif
           ! overwrite if new value is larger
           if (mask(ix,iy,iz)<tmp1*tmp2) then
              mask(ix,iy,iz) = tmp1*tmp2
              if (mask(ix,iy,iz) > 1.0e-12) then
                ! assign color "1" where >0 indicates something "useful"
                mask_color(ix,iy,iz) = 1
                ! velocity (remember: rotation around x0,y0,z0)
                y = dble(iy)*dy - y0
                z = dble(iz)*dz - z0
                R = dsqrt( y**2 + z**2  )
                un = R*alpha_t
                us(ix,iy,iz,2) = -dsin(alpha)*un
                us(ix,iy,iz,3) = +dcos(alpha)*un
              endif
           endif
        endif

     enddo
  enddo
  enddo
end subroutine Flapper


!-------------------------------------------------------------------------------
! cavity as used by romain for "open cavity" tests. the wall is from
! -2 ... -1 and +1 ... +2
! xxxx------------xxxx
! constant in all other directions. this test was used for reproducing the
! results of Benjamin's JCP for the Neumann BC
!-------------------------------------------------------------------------------
subroutine romain_open_cavity
  use mpi
  use vars
  use penalization ! mask array etc
  implicit none

  integer :: ix, iy, iz
  real (kind=pr) :: x, y, z

  ! reset everything
  mask = 0.d0
  mask_color = 0
  us = 0.d0

  do iz=ra(3),rb(3)
    do iy=ra(2),rb(2)
      do ix=ra(1),rb(1)
        x=dble(ix)*dx - 0.5*xl
        if (x<=-1.d0 .or. x>=+1.d0 ) then
          mask (ix, iy, iz) = 1.d0
          us (ix,iy,iz,1:3) = 0.d0
          ! assign color "1" where >0 indicates something "useful"
          mask_color(ix,iy,iz) = 1
        endif
      enddo
    enddo
  enddo
end subroutine romain_open_cavity



subroutine taylor_couette()
  use vars
  use penalization ! mask array etc
  implicit none

  integer :: iy, iz
  real (kind=pr) :: y, z, R, omega

  ! reset everything
  mask = 0.d0
  mask_color = 0
  us = 0.d0


  R1=0.4d0
  R2=1.0d0
  omega=1.25d0

  do iz=ra(3),rb(3)
    z = dble(iz)*dz - 0.5d0*zl
    do iy=ra(2),rb(2)
      y = dble(iy)*dy - 0.5d0*yl

      R=dsqrt(z*z+y*y)

      ! inner cylinder
      if ( R<=R1) then
        mask (:, iy, iz) = 1.d0
        mask_color(:,iy,iz) = 0
      endif

      ! outer cylinder
      if (R>=R2) then
        mask (:, iy, iz) = 1.d0
        mask_color(:,iy,iz) = 0
      endif

      ! Velocity (also suitable for smooth mask)
      if ( R<=0.5*(R1+R2)) then
        us (:,iy,iz,1) = 0.d0
        us (:,iy,iz,2) = +omega * z
        us (:,iy,iz,3) = -omega * y
      else
        us (:,iy,iz,1:3) = 0.d0
      endif

    enddo
  enddo

end subroutine


subroutine turek_wan(time)
  use vars
  use penalization
  implicit none

  integer :: iy, iz
  real(kind=pr),intent(in) :: time
  real (kind=pr) :: y, z, R, omega,A,f0,h, R0,tmp2,uu

  ! reset everything
  mask = 0.d0
  mask_color = 0
  us = 0.d0


  R0=0.05d0
  h=0.07d0
  A=0.25d0
  f0=0.25d0

  ! first we draw the channel relevant for this configuration
  do iz=ra(3),rb(3)
    z = dble(iz)*dz-h
    if ((z<=0.d0).or.(z>=0.41d0)) then
      mask(:,:,iz) = 1.d0
      us(:,:,iz,:) = 0.d0
      mask_color(:,:,iz) = 0
    endif
  enddo

  y0 = 1.1d0 + A*sin(2.0d0*pi*f0*time)
  uu = 2.0*pi*A*f0*cos(2.0d0*pi*f0*time)
  z0 = 0.41d0/2.0d0

  do iz=ra(3),rb(3)
    z = dble(iz)*dz -h
    do iy=ra(2),rb(2)
      y = dble(iy)*dy

      R = sqrt( (z-z0)**2 + (y-y0)**2 )
      if (R<2*R0) then
        call SmoothStep (tmp2, R, R0, 1.0*max(dy,dz))
        mask(:,iy,iz) = tmp2
        mask_color(:,iy,iz) = 1
        us(:,iy,iz,2) = uu
      endif
    enddo
  enddo

end subroutine



subroutine Draw_floor_yz()
  use vars
  use penalization ! mask array etc
  implicit none

  integer :: iy, iz, ix
  real (kind=pr) :: y, z, x

  ! reset everything
  mask = 0.d0
  mask_color = 0
  us = 0.d0

  do iz = ra(3), rb(3)
    do iy = ra(2), rb(2)
      do ix = ra(1), rb(1)
        x = dble(ix)*dx
        y = dble(iy)*dy
        z = dble(iz)*dz

        if (x <= thick_wall) then
          mask(ix,iy,iz) = 1.d0
          mask_color(ix,iy,iz) = 1
        endif
      enddo
    enddo
  enddo

end subroutine
