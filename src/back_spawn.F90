#include "macros.h"

module back_spawn

    use CalcData, only: t_back_spawn, tTruncInitiator, t_back_spawn_occ_virt, &
                        t_back_spawn_flex
    use SystemData, only: nel, nbasis, G1, tGen_4ind_2, tGen_4ind_2_symmetric, & 
                          tHub
    use constants, only: n_int, dp, bits_n_int, lenof_sign, inum_runs
    use bit_rep_data, only: nifd, niftot
    use fcimcdata, only: projedet, max_calc_ex_level
    use dSFMT_interface, only: genrand_real2_dSFMT
    use SymExcitDataMod, only: OrbClassCount, SymLabelCounts2, SymLabelList2, &
                               SpinOrbSymLabel
    use Parallel_neci, only: iprocindex

    implicit none

    ! i need a list to indicate the virtual orbitals in the reference 
    ! determinant: the idea of the first implementation is for non-initiators
    ! to only pick electrons from these orbitals, so that the chance to 
    ! de-excite relative to the reference determinant is higher and thus to 
    ! increase the chance to hit already occupied determinants

    ! i could use a mask in the ilut format.. 
    integer(n_int), allocatable :: mask_virt_ilut(:)

    ! or i could use a list of orbitals in the nI format
    integer, allocatable :: mask_virt_ni(:,:)

    ! and i guess it could also be wise to do it in a spatial resolved way.
    integer, allocatable :: mask_virt_spat(:)

    real(dp) :: back_spawn_factor

contains

    ! what do i need..
    subroutine init_back_spawn() 
        ! init routine
        character(*), parameter :: this_routine = "init_back_spawn"

        ! also add some output so people know we use this method
        root_print "BACK-SPAWNING method in use! "
        if (t_back_spawn_flex) then
            root_print "Flex option in use: we pick the electrons randomly" 
            root_print " and then decide, where to pick the orbitals from "
            root_print " depending where the electrons are relative to the ref"
        else
            root_print "For non-initiators we only pick electrons from the virtual"
            root_print " orbitals of the reference determinant!"
            root_print " so non-initiators only lower or keep the excitation level constant!"
        end if

        if (t_back_spawn_occ_virt) then 
            root_print "additionally option to pick the first orbital (a) from " 
            root_print " the occupied manifold of the reference is activated!"
        end if
        ! first it only makes sense if we actually use the initiator method
        if (.not. tTruncInitiator) then 
            call stop_all(this_routine, &
                "back spawning makes only sense in the initiator method!")
        end if

        if (.not. tGen_4ind_2) then 
            if (.not. tHub) then
                call stop_all(this_routine, &
                    "for molecular systems this back-spawning need 4ind-weighted-2 or above!")
            end if
        end if

        if (tGen_4ind_2_symmetric) then 
            call stop_all(this_routine, &
                "back-spawning not compatible with symmetric excitation generator!")
        end if

        ! first use the most simple implementation of an nI style 
        ! virtual orbital indication:
        if (allocated(mask_virt_ni)) deallocate(mask_virt_ni)

        ! i need to adapt that for replica runs
        allocate(mask_virt_ni(nBasis - nel, inum_runs))

        ! and assure that this routine is called after the first HFDET is 
        ! already assigned
        ASSERT(allocated(projedet))
        if (.not.allocated(projedet)) then 
            call stop_all(this_routine, &
                "init_back_spawn() called to early; run reference not yet setup!")
        end if

        call setup_virtual_mask()

        ! also change the max excitation level calculated
        max_calc_ex_level = nel

    end subroutine init_back_spawn

    subroutine setup_virtual_mask()
        ! routine to setup the list of virtual orbitals in the current 
        ! reference determinant, these are then used to choose the electrons
        ! for non-initiator determinants
        ! for now this is only done for single-runs! not dneci, mneci for now!
        character(*), parameter :: this_routine = "setup_virtual_mask"
        integer :: i, j, k

        ASSERT(allocated(projedet))

        ! i guess the easiest way to do that is to loop over all the 
        ! spin-orbitals and only write an entry if this orbital is not 
        ! occupied in the reference
        do k = 1, inum_runs
            j = 1
            do i = 1, nbasis
                ! if (i) is in the reference cycle
                if (any(i == projedet(:,k))) cycle
                ! otherwise fill up the virtual mask
                mask_virt_ni(j,k) = i
                j = j + 1
            end do
        end do

    end subroutine setup_virtual_mask

    function check_electron_location(elecs, ic, run) result(loc)
        ! routine which determines where the electrons of of an determinant 
        ! are located with respect to the reference determinant to 
        ! then decide where to pick the orbitals from.. 
        integer, intent(in) :: elecs(2), ic
        integer, intent(in) :: run
        integer :: loc
        character(*), parameter :: this_routine = "check_electron_location"

        integer :: i 
        ! the output integer encodes: 
        ! 0 ... both electrons are in the virtual space of the reference
        ! 1 ... the electrons are mixed in occupied and virtual manifold
        ! 2 ... electron(s) are/is in the refernce determinant 

        if (ic == 1) then 
            ! single exctitation 
            if (any(elecs(1) == projedet(:,part_type_to_run(run)))) then 
                ! this means the electron is in the reference determinant
                ! which means we should pick a hole also in the 
                ! reference determinant, or otherwise we definetly 
                ! increase the excitation level 
                loc = 2 

            else
                ! only option 1 and 3 for single excitations!
                loc = 0
            end if
        else if (ic == 2) then 

            ! for double excitations we have to check both
            loc = 0
            do i = 1, 2
                if (any(elecs(i) == projedet(:,part_type_to_run(run)))) then 
                    loc = loc + 1
                end if
            end do
        end if

    end function check_electron_location


    subroutine pick_virtual_electrons_double(nI, run, elecs, src, ispn, &
                                                sum_ml, pgen)
        ! this is the important routine! 
        ! for non-initiator determinants this pick electrons only from the 
        ! virtual orbitals of the reference determinant to increase the 
        ! chance to de-excite and to spawn to an already occupied 
        ! determinant from an non-initiator!
        integer, intent(in) :: nI(nel), run
        integer, intent(out) :: elecs(2), src(2), ispn, sum_ml
        real(dp), intent(out) :: pgen
        character(*), parameter :: this_routine = "pick_virtual_electrons_double"

        integer :: i, n_valid, j, ind, n_valid_pairs, ind_1, ind_2
        integer :: virt_elecs(nel)

        ! i guess for now i only want to choose uniformly from all the 
        ! available electron in the virtual orbitals of the reference

        ! what do we need here? 
        ! count all the electrons in the virtual of the reference, then 
        ! pick two random orbitals out of those! 
        ! check the routine in symrandexcit3.f90 this does the job i guess..

        n_valid = 0
        j = 1
        do i = 1, nel
            if (any(nI(i) == mask_virt_ni(:,part_type_to_run(run)))) then
                ! the electron is in the virtual of the 
                n_valid = n_valid + 1
                virt_elecs(j) = i 
                j = j + 1
            end if
        end do

        if (n_valid < 2) then
            ! something went wrong
            ! in this case i have to abort as no valid double excitation 
            ! could have been found
            elecs = 0
            src = 0
            pgen = 0.0_dp
            return
!             call stop_all(this_routine, & 
!                 "something went wront, did not find 2 valid virtual electrons!")
        end if

        ! determine how many valid pairs there are now
        n_valid_pairs = (n_valid * (n_valid - 1)) / 2

        ! and the pgen is now: 
        pgen = 1.0_dp / real(n_valid_pairs, dp)

        ! and is it now enough to do is just like in the symrandexcit3 routine:
        ind = 1 + int(n_valid_pairs * genrand_real2_dSFMT())
        ind_1 = ceiling((1 + sqrt(1 + 8*real(ind,dp))) / 2)
        ind_2 = ind - ((ind_1 - 1) * (ind_1 - 2)) / 2

        ! and retro pick the electron number from the created list? 
        elecs(1) = virt_elecs(ind_1)
        elecs(2) = virt_elecs(ind_2)

        ! hm.. test this tomorrow
        
        ! now i have to pick two random ones from the list! 
        ! all the symmetry related stuff at the end:
        src = nI(elecs)

        
        if (is_beta(src(1)) .eqv. is_beta(src(2))) then
            if (is_beta(src(1))) then
                iSpn = 1
            else
                iSpn = 3
            end if
        else
            iSpn = 2
        end if

        ! The Ml value is obtained from the orbitals
        sum_ml = sum(G1(src)%Ml)

        ! And the spatial symmetries
!         sym_prod = RandExcitSymLabelProd(SpinOrbSymLabel(src(1)), &
!                                          SpinOrbSymLabel(src(2)))

    end subroutine pick_virtual_electrons_double
    

    subroutine pick_occupied_orbital_single(nI, ilut, src, cc_index, run, pgen, orb)
        integer, intent(in) :: nI(nel), src, cc_index, run
        integer(n_int), intent(in) :: ilut(0:niftot)
        real(dp), intent(out) :: pgen
        integer, intent(out) :: orb
        ! routine to pick an orbital from the occupied manifold in the 
        ! reference determinant for single excitations
        ! i have to take symmetry into account now..  that complicates 
        ! things.. and spin.. 
        character(*), parameter :: this_routine = "pick_occupied_orbital_single"

        integer :: n_valid, j, occ_orbs(nel), i, ind, norb, label_index

        j = 1
        occ_orbs = 0

        norb = OrbClassCount(cc_index)
        label_index = SymLabelCounts2(1, cc_index)

        ! damn i did not include symmetries todo
        ! ok do it now with symmetries
        do i = 1, norb 
            orb = SymLabelList2(label_index + i - 1)
            if (any(orb == projedet(:,part_type_to_run(run))) .and. IsNotOcc(ilut,orb)) then 

                ASSERT(SpinOrbSymLabel(orb) == SpinOrbSymLabel(src))

                occ_orbs(j) = orb 
                j = j + 1
            end if 
        end do

!         do i = 1, nel
!             if (.not. any(projedet(i,1) == nI)) then 
!                 ! i also have to check spin and symmetry now.. 
!                 if (is_beta(src) .eqv. is_beta(projedet(i,1)) .and. &
!                     SpinOrbSymLabel(src) == SpinOrbSymLabel(projedet(i,1))) then
! 
!                     occ_orbs(j) = projedet(i,1)
!                     j = j + 1
!                 end if
!             end if
!         end do

        n_valid = j - 1

        if (n_valid == 0) then 
            orb = 0
            pgen = 0.0_dp
            return
        end if

        ! else pick uniformly from that available list..
        ind = 1 + int(genrand_real2_dSFMT() * n_valid)
        orb = occ_orbs(ind)

        pgen = 1.0_dp / real(n_valid, dp)

    end subroutine pick_occupied_orbital_single

    subroutine pick_occupied_orbital_hubbard(nI, run, pgen, orb) 
        ! routine to pick one possible orbital from the occupied manifold 
        ! thats the easiest of all implementations actually.. 
        integer, intent(in) :: nI(nel), run
        real(dp), intent(out) :: pgen 
        integer, intent(out) :: orb 
        character(*), parameter :: this_routine = "pick_occupied_orbital_hubbard"
        integer :: n_valid, j, occ_orbs(nel), ind, i

        n_valid = 0
        j = 1
        occ_orbs = 0
        
        do i = 1, nel 
            if (.not. any(projedet(i,part_type_to_run(run)) == nI)) then 
                n_valid = n_valid + 1
                occ_orbs(j) = i 
                j = j + 1
            end if 
        end do

        if (n_valid == 0) then 
            orb = 0
            pgen = 0.0_dp
            return
        end if

        ind = 1 + int(n_valid * genrand_real2_dSFMT())

        orb = occ_orbs(ind)

        pgen = 1.0_dp / real(n_valid, dp)


    end subroutine pick_occupied_orbital_hubbard 


    subroutine pick_occupied_orbital(nI, src, ispn, run, cpt, cum_sum, orb)
        integer, intent(in) :: nI(nel), src(2), ispn, run
        real(dp), intent(out) :: cpt, cum_sum
        integer, intent(out) :: orb
        ! routine to pick an orbital of the occupied manifold of the 
        ! reference determinant uniformly 
        ! to be compatible with the rest of the 4ind-weighted-2 
        ! excitation generators i have to be carefull with the cum_lists 
        ! and stuff..
        character(*), parameter :: this_routine = "pick_occupied_orbital"
        logical :: parallel, beta
        integer :: occ_orbs(nel), n_valid, j, ind, i

        ! soo what do i need? 
        ! i have to check if any of the possible orbitals for nI is occupied
        ! in the reference determinant! 

        ! better idea: 
        n_valid = 0
        j = 1
        occ_orbs = 0
        ! loop over ref det 
        do i = 1, nel 
            ! check if ref-det electron is NOT in nI
            if (.not. any(projedet(i,part_type_to_run(run)) == nI)) then 
                ! check the symmetry here.. or atleast the spin..
                ! if we are parallel i have to ensure the orbital has the 
                ! same spin 
                if (ispn /= 2) then 
                    if (is_beta(projedet(i,part_type_to_run(run))) .eqv. &
                        is_beta(src(1))) then
                        ! this is a valid orbital i guess.. 
                        n_valid = n_valid + 1 
                        occ_orbs(j) = projedet(i,part_type_to_run(run)) 
                        j = j + 1
                    end if
                else 
                    ! there is some weird shenanigan in the gen_a_orb_cum_list
                    ! if the spins are anti-parallel.. why?
                    ! this "only" has to do with the weighting of the 
                    ! matrix element.. so it does not affect me here i guess
                    ! so here all the orbitals are alowed..
                    ! UPDATE: nope this also implies that (a) is always a 
                    ! beta orbital for anti-parallel spin excitations
                    ! i do not know why exactly, but somebody decided to do 
                    ! it this way.. so just to be sure, also do it like that 
                    ! in the back-spawn method
                    if (is_beta(projedet(i,part_type_to_run(run)))) then 
                        n_valid = n_valid + 1
                        occ_orbs(j) = projedet(i,part_type_to_run(run))
                        j = j + 1
                    end if
                end if
            end if
        end do
        
        ! so now we have a list of the possible orbitals in occ_orbs
        ! this has to be atleast 2, or otherwise we won't find a second 
        ! orbital.. well no! since the second orbital can be picked from 
        ! all the orbitals! 
        if (n_valid == 0) then 
            orb = 0 
            cpt = 0.0_dp
            return
        end if

        ind = 1 + int(genrand_real2_dSFMT() * n_valid) 

        orb = occ_orbs(ind)

        ! and now the cum_sums and pgens.. 
        cpt = 1.0_dp / real(n_valid, dp)
        cum_sum = 1.0_dp


    end subroutine pick_occupied_orbital

    subroutine pick_second_occupied_orbital(nI, src, cc_b, orb_a, ispn, run, cpt, cum_sum, &
                                            orb) 
        ! routine which picks second orbital from the occupied manifold for 
        ! a double excitation. this function gets called if we have picked 
        ! two electrons also from the occupied manifold in the flex version 
        ! of the back-spawning method. to ensure we keep the excitation 
        ! level the same but also increase the flexibility of the method
        ! this now has to take symmetries into account, which makes it a 
        ! bit more complicated
        integer, intent(in) :: nI(nel), src(2), cc_b, orb_a, ispn, run
        real(dp), intent(out) :: cpt, cum_sum
        integer, intent(out) :: orb
        character(*), parameter :: this_routine = "pick_second_occupied_orbital"

        integer :: label_index, norb, sym_orbs(OrbClassCount(cc_b))
        integer :: i, n_valid, occ_orbs(nel), j, ind
        ! i need to take symmetry and spin into account for the valid 
        ! "occupied" orbitals. 
        ! because we have picked the first indepenent of spin and symmetry
        
        ! i could compare the reference det and the symmetry allowed list 
        ! of orbitals
        label_index = SymLabelCounts2(1, cc_b)
        norb = OrbClassCount(cc_b) 

        ! create the symmetry allowed orbital list
        do i = 1, norb
            sym_orbs(i) = SymLabelList2(label_index + i - 1)
        end do

        j = 1
        ! check which occupied orbitals fit all the restrictions:
        ! or i guess this is already covered in the symlabel list!
        ! check that!
        if (ispn == 2) then
            ! then we want the opposite spin of orb_a!
            do i = 1, nel 
                ! check if in occupied manifold
                if (.not. any(projedet(i,part_type_to_run(run)) == nI)) then 
                    ! check if symmetry fits
                    if (any(projedet(i,part_type_to_run(run)) == sym_orbs)) then 
                        ! and check if spin is opposit 
                        if (.not. (is_beta(orb_a) .eqv. &
                            is_beta(projedet(i,part_type_to_run(run))))) then 
                            occ_orbs(j) = projedet(i,part_type_to_run(run))
                            j = j + 1
                        end if
                    end if
                end if
            end do
        else
            ! otherwise we want the same spin but have to ensure it is not 
            ! already picked orbital (a)
            do i = 1, nel
                if (.not. any(projedet(i,part_type_to_run(run)) == nI)) then 
                    if (any(projedet(i,part_type_to_run(run)) == sym_orbs)) then 
                        if (is_beta(orb_a) .eqv. &
                            is_beta(projedet(i,part_type_to_run(run))) .and. &
                            orb_a /= projedet(i,part_type_to_run(run))) then 

                            occ_orbs(j) = projedet(i,part_type_to_run(run)) 
                            j = j + 1
                        end if
                    end if
                end if
            end do
        end if

        n_valid = j - 1

        if (n_valid == 0) then 
            orb = 0
            cpt = 0.0_dp
            cum_sum = 1.0_dp
            return
        end if

        ind = 1 + int(genrand_real2_dSFMT() * n_valid)

        orb = occ_orbs(ind)
        cpt = 1.0_dp / real(n_valid, dp)
        cum_sum = 1.0_dp

    end subroutine pick_second_occupied_orbital

    subroutine pick_virtual_electrons_double_hubbard(nI, run, elecs, src, ispn, pgen)
        ! specific routine to pick 2 electrons in the k-space hubbard, 
        ! since apparently it is important to allow all orderings of 
        ! electrons possible.. although this could just be a artifact of the 
        ! old hubbard excitation generation
        integer, intent(in) :: nI(nel), run
        integer, intent(out) :: elecs(2), src(2), ispn
        real(dp), intent(out) :: pgen
        character(*), parameter :: this_routine = "pick_virtual_electrons_double_hubbard"

        integer :: n_valid, i, j, n_valid_pairs, ind_1, ind_2
        integer :: virt_elecs(nel)
        integer :: n_beta, n_alpha
        ! but it is also good to to it here so i can do it more cleanly
        n_valid = 0

        n_beta = 0
        n_alpha = 0
        ! actually for the correct generation probabilities i have to count 
        ! the number of valid alpha and beta electrons!
        j = 1
        do i = 1, nel
            if (any(nI(i) == mask_virt_ni(:,part_type_to_run(run)))) then
                if (is_beta(nI(i)))  n_beta = n_beta + 1
                if (is_alpha(nI(i))) n_alpha = n_alpha + 1
                ! the electron is in the virtual of the 
                n_valid = n_valid + 1
                virt_elecs(j) = i
                j = j + 1
            end if
        end do

        ! in the hubbard case i also have to check if there is atleast on 
        ! pair possible with opposite spin
        if (n_valid < 2 .or. n_beta == 0 .or. n_alpha == 0) then
            ! something went wrong
            ! in this case i have to abort as no valid double excitation 
            ! could have been found
            elecs = 0
            src = 0
            pgen = 0.0_dp
            return
!             call stop_all(this_routine, & 
!                 "something went wront, did not find 2 valid virtual electrons!")
        end if

        ! apparently i have to have both ordering of the electrons in 
        ! the hubbard excitation generator 
        ! but it must be easier to do that... and more efficient
        do i = 1, 1000
            ind_1 = 1 + int(n_valid * genrand_real2_dSFMT())

            do j = 1, 1000
                ind_2 = 1 + int(n_valid * genrand_real2_dSFMT())

                if (ind_1 /= ind_2) exit
            end do

            elecs(1) = virt_elecs(ind_1)
            elecs(2) = virt_elecs(ind_2)
            src = nI(elecs)

            if (is_beta(src(1)) .neqv. is_beta(src(2))) then
                ispn = 2
                exit
            end if
        end do

        if (i > 999 .or. j > 999) then 
            print *, "something went wrong, did not find two valid electrons!"
            print *, "nI: ", nI
            print *, "mask_virt_ni:", mask_virt_ni(:,part_type_to_run(run))
            print *, "virt_elecs: ", virt_elecs
        end if

        
        pgen = 1.0_dp / real(n_alpha * n_beta, dp)

    end subroutine pick_virtual_electrons_double_hubbard

    subroutine pick_virtual_electron_single(nI, run, elec, pgen_elec)
        ! same as above for a single excitation
        ! remember: elec is really just the number in the ilut!
        integer, intent(in) :: nI(nel), run
        integer, intent(out) :: elec
        real(dp), intent(out) :: pgen_elec
        character(*), parameter :: this_routine = "pick_virtual_electron_single"

        integer :: i, n_valid, j, ind
        integer:: virt_elecs(nel)

        ! what do we need here? 
        ! count all the electrons in the virtual of the reference, then 
        ! create a list of them and pick one uniformly
        n_valid = 0
        j = 1
        do i = 1, nel
            if (any(nI(i) == mask_virt_ni(:,part_type_to_run(run)))) then
                ! the electron is in the virtual of the 
                n_valid = n_valid + 1
                virt_elecs(j) = i
                j = j + 1
            end if
        end do

        if (n_valid == 0) then
            ! something went wrong
            call stop_all(this_routine, & 
                "something went wront, did not find valid virtual single electron!")
        end if

        ! and now pick a random number: 
        ind = 1 + floor(genrand_real2_dSFMT() * n_valid) 

        elec = virt_elecs(ind)

        pgen_elec = 1.0_dp / real(n_valid, dp)

    end subroutine pick_virtual_electron_single

end module back_spawn

